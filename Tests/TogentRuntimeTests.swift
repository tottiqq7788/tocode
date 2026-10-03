import Foundation

private final class TogentSynchronizedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    func set(_ value: Bool) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

func testTogentJSONLFramingAndReplyChunks() {
    var framer = TogentJSONLFramer()
    let first = Data(#"{"type":"message","text":"甲\u2028乙"}"#.utf8)
    let payload = first + Data("\n{\"type\":\"agent_settled\"}\r\npartial".utf8)
    let records = framer.append(payload)
    expect(records.count == 2, "Togent JSONL 只按 LF 分帧")
    expect(records.first == first, "Togent JSONL 不把 U+2028 当分隔符")
    expect(String(data: records[1], encoding: .utf8) == #"{"type":"agent_settled"}"#,
           "Togent JSONL 接受并去掉 CRLF 中的 CR")
    expect(String(data: framer.buffer, encoding: .utf8) == "partial",
           "Togent JSONL 保留未完成记录")

    let text = String(repeating: "甲", count: 3_700)
    let chunks = TogentReplyChunker.chunks(text)
    expect(chunks.count == 3, "微信 Agent 长回复按上限分块")
    expect(chunks.allSatisfy { $0.count <= 1_800 }, "微信 Agent 每块不超过字符上限")
    expect(chunks.joined() == text, "微信 Agent 分块不丢字符")
}

func testTogentRelayInternalCredentialAndHealthModels() {
    let reference = ModelRelayUpstreamKeyReference(name: "key")
    let provider = ModelRelayProvider(
        name: "厂家A",
        baseURL: "https://example.invalid/v1",
        keys: [reference],
        models: [
            ModelRelayModelRoute(upstreamModelID: "upstream", alias: "published")
        ]
    )
    let keyStore = MemoryModelRelayKeyStore([reference.id: "upstream-secret"])
    let token = "tg_test_ephemeral"
    let router = ModelRelayRouter(
        configuration: ModelRelayConfiguration(providers: [provider]),
        keyStore: keyStore,
        vault: ModelRelayLocalKeyVault(iterations: 1),
        internalCredentialDigest: ModelRelayLocalKeyVault.digest(token)
    )
    var availabilityChanges = 0
    router.availabilityDidChange = {
        availabilityChanges += 1
    }
    expect(router.authenticate(token), "Relay 接受 Togent 进程内临时 token")
    expect(!router.authenticate("wrong"), "Relay 拒绝错误 Togent token")
    expect(
        router.availableTogentModels()
            == [TogentModelOption(publishedModelID: "published", providerName: "厂家A")],
        "Togent 模型列表只呈现健康厂家与发布模型名"
    )
    router.recordFailure(keyID: reference.id, statusCode: 401)
    expect(router.availableTogentModels().isEmpty, "厂家鉴权失败后模型立即从 Togent 列表消失")
    expect(availabilityChanges == 1, "厂家健康可用性变化会通知 Togent")
    router.recordFailure(keyID: reference.id, statusCode: 401)
    expect(availabilityChanges == 1, "重复失败不重复通知相同可用性")
    router.recordSuccess(keyID: reference.id)
    expect(availabilityChanges == 2, "厂家恢复健康会通知 Togent")
    router.update(configuration: ModelRelayConfiguration())
    expect(router.availableTogentModels().isEmpty, "厂家删除后 Togent 不保留陈旧模型")
}

func testTogentSandboxProfileAndEnvironment() {
    let root = makeTogentTemporaryDirectory("sandbox")
    defer { try? FileManager.default.removeItem(at: root) }
    let canonicalRoot = root.resolvingSymlinksInPath()
    let workspace = canonicalRoot.appendingPathComponent("workspace", isDirectory: true)
    let runtimeParent = canonicalRoot.appendingPathComponent("runtime", isDirectory: true)
    let runtime = runtimeParent.appendingPathComponent("role-a", isDirectory: true)
    let otherRuntime = runtimeParent.appendingPathComponent("role-b", isDirectory: true)
    let otherSession = otherRuntime.appendingPathComponent(
        "sessions/session.json"
    )
    let archive = workspace.appendingPathComponent("wechat", isDirectory: true)
    let otherWorkspace = canonicalRoot.appendingPathComponent("other-workspace", isDirectory: true)
    let otherArchive = otherWorkspace.appendingPathComponent("wechat", isDirectory: true)
    let bundle = canonicalRoot.appendingPathComponent("bundle", isDirectory: true)
    for directory in [workspace, runtime, archive, otherArchive, otherRuntime, bundle] {
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try! "本角色历史".write(
        to: archive.appendingPathComponent("own.md"),
        atomically: true,
        encoding: .utf8
    )
    try! "其他角色历史".write(
        to: otherArchive.appendingPathComponent("other.md"),
        atomically: true,
        encoding: .utf8
    )
    try! FileManager.default.createDirectory(
        at: otherSession.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try! "其他角色会话".write(
        to: otherSession,
        atomically: true,
        encoding: .utf8
    )
    let sandbox = TogentSandbox(applicationSupportRoot: runtimeParent)
    let profile = sandbox.profileText(
        workspace: workspace,
        runtimeRoot: runtime,
        bundledRuntime: bundle
    )
    expect(profile.contains("/workspace"), "沙箱只显式放行角色工作区")
    expect(profile.contains("/workspace/wechat"), "沙箱把本角色微信归档设为只读")
    expect(!profile.contains("/other-workspace"), "沙箱不暴露其他角色工作区")
    expect(profile.contains(#"(deny mach-lookup"#), "沙箱显式拒绝钥匙串与剪贴板服务")

    let role = makeTogentRole(workspace: workspace)
    let access = TogentRelayAccess(
        baseURL: "http://127.0.0.1:27800/v1",
        bearerToken: "secret-in-memory",
        models: [TogentModelOption(publishedModelID: "model-a", providerName: "厂家")]
    )
    let layout = try! sandbox.prepare(role: role, bundledRuntime: bundle, relayAccess: access)
    let environment = TogentSandbox.safeEnvironment(layout: layout, relayToken: access.bearerToken)
    expect(environment["SSH_AUTH_SOCK"] == nil, "Pi 环境不传 SSH_AUTH_SOCK")
    expect(environment["HOME"] != FileManager.default.homeDirectoryForCurrentUser.path,
           "Pi 环境不暴露用户 HOME")
    let models = try! String(contentsOf: layout.modelsFile, encoding: .utf8)
    expect(models.contains("${TOGENT_RELAY_KEY}"), "models.json 只引用环境变量 token")
    expect(!models.contains(access.bearerToken), "models.json 不落临时 token 明文")

    let outside = canonicalRoot.appendingPathComponent("outside-secret.txt")
    try! "secret".write(to: outside, atomically: true, encoding: .utf8)
    let profileURL = canonicalRoot.appendingPathComponent("test.sb")
    try! profile.write(to: profileURL, atomically: true, encoding: .utf8)

    func sandboxResult(_ command: String) -> (Int32, String) {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", profileURL.path, "/bin/sh", "-c", command]
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try! process.run()
        process.waitUntilExit()
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (process.terminationStatus, error)
    }
    let allowedFile = workspace.appendingPathComponent("allowed.txt")
    let allowedResult = sandboxResult("printf ok > '\(allowedFile.path)'")
    if allowedResult.0 != 0 {
        print("沙箱允许写诊断：\(allowedResult.1)")
    }
    expect(
        allowedResult.0 == 0,
        "sandbox-exec 允许运行时写当前角色工作区"
    )
    expect(
        sandboxResult("cat '\(outside.path)' >/dev/null").0 != 0,
        "sandbox-exec 拒绝读取角色边界外用户文件"
    )
    expect(
        sandboxResult("cat '\(archive.appendingPathComponent("own.md").path)' >/dev/null").0 == 0,
        "sandbox-exec 允许只读查询本角色微信归档"
    )
    expect(
        sandboxResult("printf bad > '\(archive.appendingPathComponent("bad.txt").path)'").0 != 0,
        "sandbox-exec 拒绝修改本角色微信归档"
    )
    expect(
        sandboxResult("cat '\(otherArchive.appendingPathComponent("other.md").path)' >/dev/null").0 != 0,
        "sandbox-exec 拒绝读取其他角色微信归档"
    )
    expect(
        sandboxResult("cat '\(otherSession.path)' >/dev/null").0 != 0,
        "sandbox-exec 拒绝读取其他角色 Pi 会话"
    )
}

func testTogentRPCWaitsForAgentSettled() async {
    let root = makeTogentTemporaryDirectory("rpc")
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("fake-pi.py")
    let source = """
    #!/usr/bin/python3
    import json
    import sys
    import time
    for line in sys.stdin:
        command = json.loads(line)
        kind = command["type"]
        if kind == "get_state":
            print(json.dumps({"id": command["id"], "type": "response", "command": kind, "success": True, "data": {}}), flush=True)
        elif kind == "prompt":
            print(json.dumps({"id": command["id"], "type": "response", "command": kind, "success": True, "data": {"disposition": "started"}}), flush=True)
            print(json.dumps({"type": "agent_end"}), flush=True)
            time.sleep(0.15)
            print(json.dumps({"type": "agent_settled"}), flush=True)
        elif kind == "get_last_assistant_text":
            print(json.dumps({"id": command["id"], "type": "response", "command": kind, "success": True, "data": {"text": "最终回复"}}), flush=True)
    """
    try! source.write(to: script, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: script.path
    )
    let client = TogentRPCClient(
        executableURL: script,
        arguments: [],
        environment: ["PATH": "/usr/bin:/bin"],
        workingDirectory: root,
        commandTimeout: 2,
        promptTimeout: 2
    )
    try! client.start()
    let started = Date()
    let answer = try! await client.promptAndWait("测试")
    let elapsed = Date().timeIntervalSince(started)
    client.stop()
    expect(answer == "最终回复", "Togent RPC 在 settled 后读取最后 assistant 文本")
    expect(elapsed >= 0.12, "Togent RPC 不把 prompt response 或 agent_end 当完成")
}

func testTogentRPCCrashAndTimeoutFaults() async {
    let root = makeTogentTemporaryDirectory("rpc-faults")
    defer { try? FileManager.default.removeItem(at: root) }

    func makeClient(
        name: String,
        source: String,
        promptTimeout: TimeInterval
    ) -> TogentRPCClient {
        let script = root.appendingPathComponent(name)
        try! source.write(to: script, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: script.path
        )
        return TogentRPCClient(
            executableURL: script,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: root,
            commandTimeout: 1,
            promptTimeout: promptTimeout
        )
    }

    let crashClient = makeClient(
        name: "crash.py",
        source: """
        #!/usr/bin/python3
        import json
        import sys
        for line in sys.stdin:
            command = json.loads(line)
            kind = command["type"]
            if kind == "get_state":
                print(json.dumps({"id": command["id"], "type": "response", "command": kind, "success": True, "data": {}}), flush=True)
            elif kind == "prompt":
                print(json.dumps({"id": command["id"], "type": "response", "command": kind, "success": True, "data": {"disposition": "started"}}), flush=True)
                print("forced Pi crash", file=sys.stderr, flush=True)
                sys.exit(7)
        """,
        promptTimeout: 1
    )
    do {
        try crashClient.start()
        _ = try await crashClient.promptAndWait("崩溃测试")
        expect(false, "Pi 崩溃应结束等待中的 RPC")
    } catch TogentError.runtimeExited(let message) {
        expect(message.contains("forced Pi crash"), "Pi 崩溃保留 stderr 诊断")
    } catch {
        expect(false, "Pi 崩溃应返回 runtimeExited：\(error)")
    }
    crashClient.stop()

    let timeoutClient = makeClient(
        name: "timeout.py",
        source: """
        #!/usr/bin/python3
        import json
        import sys
        for line in sys.stdin:
            command = json.loads(line)
            kind = command["type"]
            if kind == "get_state":
                print(json.dumps({"id": command["id"], "type": "response", "command": kind, "success": True, "data": {}}), flush=True)
            elif kind == "prompt":
                print(json.dumps({"id": command["id"], "type": "response", "command": kind, "success": True, "data": {"disposition": "started"}}), flush=True)
                for _ in sys.stdin:
                    pass
                break
        """,
        promptTimeout: 0.1
    )
    do {
        try timeoutClient.start()
        _ = try await timeoutClient.promptAndWait("超时测试")
        expect(false, "未 settled 的 Pi prompt 应超时")
    } catch TogentError.rpcTimeout {
        expect(true, "未 settled 的 Pi prompt 返回明确超时")
    } catch {
        expect(false, "Pi prompt 超时应返回 rpcTimeout：\(error)")
    }
    timeoutClient.stop()
}

func testTogentGitBrokerRejectsUncontrolledOperations() {
    let root = makeTogentTemporaryDirectory("git")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project", isDirectory: true)
    try! FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let socket = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("tocode-git-test-\(UUID().uuidString.prefix(8)).sock")
    let broker = TogentGitBroker(socketURL: socket, projectRoot: project)
    try! broker.start()
    defer {
        broker.stop()
        try? FileManager.default.removeItem(at: socket)
    }
    let deadline = Date().addingTimeInterval(2)
    while !FileManager.default.fileExists(atPath: socket.path), Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }

    let helper = root.appendingPathComponent("request.py")
    let helperSource = """
    import json, socket, sys
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sys.argv[1])
    s.sendall(sys.stdin.buffer.read() + b"\\n")
    data = b""
    while b"\\n" not in data:
        chunk = s.recv(65536)
        if not chunk: break
        data += chunk
    print(data.decode("utf-8"))
    """
    try! helperSource.write(to: helper, atomically: true, encoding: .utf8)

    func request(_ object: [String: Any]) -> [String: Any] {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper.path, socket.path]
        process.standardInput = input
        process.standardOutput = output
        try! process.run()
        input.fileHandleForWriting.write(
            try! JSONSerialization.data(withJSONObject: object)
        )
        try! input.fileHandleForWriting.close()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
    }

    let globalConfig = request([
        "operation": "config",
        "repositoryPath": project.path,
        "arguments": ["--global", "user.name", "bad"]
    ])
    expect(globalConfig["ok"] as? Bool == false, "Git broker 拒绝修改全局配置")

    let forcedPush = request([
        "operation": "push",
        "repositoryPath": project.path,
        "arguments": ["--force"]
    ])
    expect(forcedPush["ok"] as? Bool == false, "Git broker 拒绝 force push")

    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try! FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    git.arguments = ["init", outside.path]
    try! git.run()
    git.waitUntilExit()
    let outsideFetch = request([
        "operation": "fetch",
        "repositoryPath": outside.path,
        "arguments": []
    ])
    expect(outsideFetch["ok"] as? Bool == false, "Git broker 拒绝角色 project 外路径")
}

func testRealPiThroughSandboxAndRelay() async {
    let runtimeDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/togent-runtime", isDirectory: true)
    guard FileManager.default.isExecutableFile(
        atPath: runtimeDirectory.appendingPathComponent("pi").path
    ) else {
        print("SKIP: 真 Pi E2E（先运行 scripts/build_togent_runtime.sh）")
        return
    }

    let root = makeTogentTemporaryDirectory("real-pi")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspaceService = TogentWorkspaceService(homeDirectory: root)
    let rawWorkspace = root.appendingPathComponent("workspace", isDirectory: true)
    let canonicalWorkspace = try! workspaceService.canonicalPath(rawWorkspace.path)
    let role = TogentRole(
        name: "E2E",
        workspacePath: canonicalWorkspace,
        prompt: "只执行当前测试任务。",
        publishedModelID: "e2e-model",
        isActive: true
    )
    _ = try! workspaceService.provision(role: role)

    let upstreamKey = ModelRelayUpstreamKeyReference(name: "e2e-upstream")
    let provider = ModelRelayProvider(
        name: "E2E 厂家",
        baseURL: "https://e2e.example/v1",
        keys: [upstreamKey],
        models: [
            ModelRelayModelRoute(upstreamModelID: "upstream-e2e", alias: "e2e-model")
        ]
    )
    let token = "tg_e2e_only"
    let router = ModelRelayRouter(
        configuration: ModelRelayConfiguration(providers: [provider]),
        keyStore: MemoryModelRelayKeyStore([upstreamKey.id: "upstream-secret"]),
        vault: ModelRelayLocalKeyVault(iterations: 1),
        internalCredentialDigest: ModelRelayLocalKeyVault.digest(token)
    )
    let sawRewrittenModel = TogentSynchronizedFlag()
    ModelRelayURLProtocol.reset { request in
        let body = try? JSONSerialization.jsonObject(
            with: modelRelayURLRequestBody(request)
        ) as? [String: Any]
        sawRewrittenModel.set(body?["model"] as? String == "upstream-e2e")
        let first = """
        data: {"id":"chatcmpl-e2e","object":"chat.completion.chunk","created":1,"model":"upstream-e2e","choices":[{"index":0,"delta":{"role":"assistant","content":"真实 Pi E2E 完成"},"finish_reason":null}]}

        """
        let final = """
        data: {"id":"chatcmpl-e2e","object":"chat.completion.chunk","created":1,"model":"upstream-e2e","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}

        data: [DONE]

        """
        return ModelRelayStubResponse(
            status: 200,
            headers: ["Content-Type": "text/event-stream"],
            chunks: [Data((first + "\n").utf8), Data(final.utf8)]
        )
    }
    let relayServer = ModelRelayHTTPServer(
        router: router,
        upstream: ModelRelayUpstreamClient(
            sessionConfiguration: modelRelayTestSessionConfiguration()
        )
    )
    let port: UInt16
    do {
        port = try await startModelRelayTestServerOnAvailablePort(relayServer)
    } catch {
        expect(false, "真 Pi E2E 应能启动受控 Relay：\(error)")
        return
    }
    defer { relayServer.stop() }

    let access = TogentRelayAccess(
        baseURL: "http://127.0.0.1:\(port)/v1",
        bearerToken: token,
        models: [
            TogentModelOption(publishedModelID: "e2e-model", providerName: "E2E 厂家")
        ]
    )
    let runtime = TogentRuntimeService(
        relayAccess: { access },
        runtimeDirectory: runtimeDirectory,
        sandbox: TogentSandbox(
            applicationSupportRoot: root.appendingPathComponent("runtime", isDirectory: true)
        )
    )
    do {
        let answer = try await runtime.execute(role: role, prompt: "请回复测试完成。")
        expect(answer.contains("真实 Pi E2E 完成"), "真 Pi RPC 经 sandbox 与受控 Relay 完成 prompt")
        let roleRuntime = root
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent(role.id.uuidString, isDirectory: true)
        let sessions = roleRuntime.appendingPathComponent("sessions", isDirectory: true)
        let sessionFiles = (try? FileManager.default.contentsOfDirectory(
            at: sessions,
            includingPropertiesForKeys: nil
        )) ?? []
        let sessionPermissions = sessionFiles.compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)[
                .posixPermissions
            ] as? NSNumber)?.intValue
        }
        expect(
            !sessionPermissions.isEmpty && sessionPermissions.allSatisfy { $0 == 0o600 },
            "Pi 持久会话文件权限为 0600"
        )
        var leakedToken = false
        if let enumerator = FileManager.default.enumerator(
            at: roleRuntime,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) {
            for case let file as URL in enumerator {
                if let data = try? Data(contentsOf: file),
                   data.range(of: Data(token.utf8)) != nil {
                    leakedToken = true
                    break
                }
            }
        }
        expect(!leakedToken, "Togent 内部 token 不进入 runtime、配置或会话文件")
    } catch {
        expect(false, "真 Pi RPC E2E 不应失败：\(error.localizedDescription)")
    }
    expect(sawRewrittenModel.value, "真 Pi 请求经 Relay 改写上游模型")
    await runtime.stopAll()
}
