import Foundation
import AppKit

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

    let plainReply = try! TogentReply.parse("普通文本回复")
    expect(
        plainReply == TogentReply(text: "普通文本回复"),
        "Togent 纯文本最终回复保持向后兼容"
    )
    let fileReply = try! TogentReply.parse(
        """
        文件已准备好。
        <tocode_wechat_files>
        {"files":["AGENTS.md","project/demo/说明.txt"]}
        </tocode_wechat_files>
        """
    )
    expect(fileReply.text == "文件已准备好。", "文件控制块不进入用户可见文本")
    expect(
        fileReply.relativeFilePaths == ["AGENTS.md", "project/demo/说明.txt"],
        "文件控制块保留工作区相对路径顺序"
    )
    let fileOnlyReply = try! TogentReply.parse(
        """
        <tocode_wechat_files>
        {"files":["AGENTS.md"]}
        </tocode_wechat_files>
        """
    )
    expect(fileOnlyReply.text.isEmpty, "只发送文件时允许空文本")

    let invalidReplies = [
        "<tocode_wechat_files>{\"files\":[\"/tmp/a\"]}</tocode_wechat_files>",
        "<tocode_wechat_files>{\"files\":[\"../a\"]}</tocode_wechat_files>",
        "<tocode_wechat_files>{\"files\":[\"a\",\"a\"]}</tocode_wechat_files>",
        "<tocode_wechat_files>{\"files\":[\"1\",\"2\",\"3\",\"4\",\"5\",\"6\"]}</tocode_wechat_files>",
        "<tocode_wechat_files>{\"files\":[\"a\"],\"extra\":true}</tocode_wechat_files>",
        "<tocode_wechat_files>{\"files\":[\"a\"]}</tocode_wechat_files>尾随文字",
        "<tocode_wechat_files>{broken}</tocode_wechat_files>"
    ]
    expect(
        invalidReplies.allSatisfy {
            do {
                _ = try TogentReply.parse($0)
                return false
            } catch TogentError.invalidReplyProtocol {
                return true
            } catch {
                return false
            }
        },
        "文件控制块拒绝绝对路径、穿越、重复、超量、额外字段、非终态和损坏 JSON"
    )
}

func testTogentRelayInternalCredentialAndHealthModels() {
    let reference = ModelRelayUpstreamKeyReference(name: "key")
    let provider = ModelRelayProvider(
        name: "厂家A",
        baseURL: "https://example.invalid/v1",
        keys: [reference],
        models: [
            ModelRelayModelRoute(
                upstreamModelID: "upstream",
                alias: "published",
                capability: ModelRelayModelCapability(
                    imageInput: .multimodal,
                    evidence: .imageProbe,
                    checkedAt: Date(),
                    probeVersion: ModelRelayModelCapability.currentProbeVersion
                )
            )
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
            == [TogentModelOption(
                publishedModelID: "published",
                providerName: "厂家A",
                imageInput: .multimodal
            )],
        "Togent 模型列表投影健康厂家、发布模型名与图片能力"
    )
    expect(
        router.togentModelFingerprintsForHealthObservation() == ["published|multimodal"],
        "Togent 健康指纹纳入图片输入能力"
    )
    let menuItem = TogentPrompts.modelMenuItem(
        for: TogentModelOption(
            publishedModelID: "published",
            providerName: "厂家A",
            imageInput: .multimodal
        )
    )
    expect(
        menuItem.title.contains("多模态")
            && menuItem.image?.accessibilityDescription == "多模态",
        "角色模型下拉以 photo 图标和明确文字标出多模态"
    )
    let unknownItem = TogentPrompts.modelMenuItem(
        for: TogentModelOption(
            publishedModelID: "unknown",
            providerName: "厂家A",
            imageInput: .unknown
        )
    )
    expect(
        unknownItem.title.contains("能力未知")
            && unknownItem.image?.accessibilityDescription == "能力未知",
        "角色模型下拉明确标出能力未知"
    )
    var unverifiedProvider = provider
    unverifiedProvider.models = [
        ModelRelayModelRoute(
            upstreamModelID: "upstream",
            alias: "published",
            capability: ModelRelayModelCapability(
                imageInput: .multimodal,
                checkedAt: Date(),
                probeVersion: ModelRelayModelCapability.currentProbeVersion
            )
        )
    ]
    router.update(configuration: ModelRelayConfiguration(providers: [unverifiedProvider]))
    expect(
        router.availableTogentModels().first?.imageInput == .unknown
            && router.togentModelFingerprintsForHealthObservation()
                == ["published|unknown"],
        "缺少 imageProbe 证据的多模态元数据按能力未知降级"
    )
    router.update(configuration: ModelRelayConfiguration(providers: [provider]))
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
        models: [
            TogentModelOption(
                publishedModelID: "model-a",
                providerName: "厂家",
                imageInput: .multimodal
            ),
            TogentModelOption(
                publishedModelID: "model-b",
                providerName: "厂家",
                imageInput: .textOnly
            ),
            TogentModelOption(
                publishedModelID: "model-c",
                providerName: "厂家",
                imageInput: .unknown
            )
        ]
    )
    let layout = try! sandbox.prepare(role: role, bundledRuntime: bundle, relayAccess: access)
    let environment = TogentSandbox.safeEnvironment(layout: layout, relayToken: access.bearerToken)
    expect(environment["SSH_AUTH_SOCK"] == nil, "Pi 环境不传 SSH_AUTH_SOCK")
    expect(environment["HOME"] != FileManager.default.homeDirectoryForCurrentUser.path,
           "Pi 环境不暴露用户 HOME")
    expect(
        environment["TOGENT_REDACT_PERSISTED_IMAGES"] == "1",
        "受管 Pi 在写盘前启用图片正文脱敏"
    )
    let models = try! String(contentsOf: layout.modelsFile, encoding: .utf8)
    expect(models.contains("${TOGENT_RELAY_KEY}"), "models.json 只引用环境变量 token")
    expect(!models.contains(access.bearerToken), "models.json 不落临时 token 明文")
    let modelObject = try! JSONSerialization.jsonObject(
        with: Data(models.utf8)
    ) as! [String: Any]
    let providers = modelObject["providers"] as! [String: Any]
    let tocode = providers["tocode"] as! [String: Any]
    let entries = tocode["models"] as! [[String: Any]]
    let inputs = Dictionary(uniqueKeysWithValues: entries.map {
        ($0["id"] as! String, $0["input"] as! [String])
    })
    expect(inputs["model-a"] == ["text", "image"], "确认多模态模型在 models.json 声明图片输入")
    expect(inputs["model-b"] == ["text"], "纯文本模型在 models.json 仅声明文本输入")
    expect(inputs["model-c"] == ["text"], "能力未知模型按纯文本安全降级")
    let settings = try! String(contentsOf: layout.settingsFile, encoding: .utf8)
    expect(
        settings.contains("\"autoResize\" : false"),
        "受管单文件 Pi 禁用不可用的图片缩放 worker，避免 read 静默丢图"
    )
    let settingsMode = (try? FileManager.default.attributesOfItem(
        atPath: layout.settingsFile.path
    )[.posixPermissions] as? NSNumber)?.intValue
    expect(settingsMode == 0o600, "受管 Pi 图片设置文件权限为 0600")

    let session = layout.sessions.appendingPathComponent("image-session.jsonl")
    let sessionImage = "session-image-base64-must-not-persist"
    let sessionLine = """
    {"type":"message","message":{"role":"toolResult","content":[{"type":"text","text":"read image"},{"type":"image","data":"\(sessionImage)","mimeType":"image/jpeg"}]}}
    """
    try! Data((sessionLine + "\n").utf8).write(to: session)
    try! sandbox.redactPersistedSessionImages(in: layout.sessions)
    let redactedSession = try! String(contentsOf: session, encoding: .utf8)
    expect(!redactedSession.contains(sessionImage), "持久 Pi 会话不保留图片 base64")
    expect(
        redactedSession.contains("已从持久会话移除归档图片正文"),
        "持久 Pi 会话以可重读路径语义替代图片正文"
    )
    let sessionMode = (try? FileManager.default.attributesOfItem(
        atPath: session.path
    )[.posixPermissions] as? NSNumber)?.intValue
    expect(sessionMode == 0o600, "脱敏后的 Pi 会话权限固定为 0600")

    let otherRoleSessions = runtimeParent
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
    try! FileManager.default.createDirectory(
        at: otherRoleSessions,
        withIntermediateDirectories: true
    )
    let otherRoleSession = otherRoleSessions.appendingPathComponent("private.jsonl")
    let otherRoleImage = "other-role-image-must-remain"
    try! Data(
        """
        {"type":"message","message":{"content":[{"type":"image","data":"\(otherRoleImage)","mimeType":"image/png"}]}}

        """.utf8
    ).write(to: otherRoleSession)
    try! FileManager.default.removeItem(at: layout.sessions)
    try! FileManager.default.createSymbolicLink(
        at: layout.sessions,
        withDestinationURL: otherRoleSessions
    )
    var rejectedCrossRoleSessionLink = false
    do {
        try sandbox.redactPersistedSessionImages(in: layout.sessions)
    } catch {
        rejectedCrossRoleSessionLink = true
    }
    expect(rejectedCrossRoleSessionLink, "Pi 会话脱敏拒绝 sessions 跨角色 symlink")
    let untouchedOtherRoleSession = try! String(
        contentsOf: otherRoleSession,
        encoding: .utf8
    )
    expect(
        untouchedOtherRoleSession.contains(otherRoleImage),
        "拒绝跨角色 sessions symlink 时不改写目标角色文件"
    )

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

private func directoryContains(_ needle: Data, under root: URL) -> Bool {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey]
    ) else {
        return false
    }
    for case let file as URL in enumerator {
        if let data = try? Data(contentsOf: file),
           data.range(of: needle) != nil {
            return true
        }
    }
    return false
}

func testRealPiThroughSandboxAndRelay() async {
    let runtimeDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/togent-runtime", isDirectory: true)
    guard FileManager.default.isExecutableFile(
        atPath: runtimeDirectory.appendingPathComponent("pi").path
    ) else {
        expect(false, "真 Pi E2E 缺少受管 runtime")
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
        expect(
            !directoryContains(Data(token.utf8), under: roleRuntime),
            "Togent 内部 token 不进入 runtime、配置或会话文件"
        )
    } catch {
        expect(false, "真 Pi RPC E2E 不应失败：\(error.localizedDescription)")
    }
    expect(sawRewrittenModel.value, "真 Pi 请求经 Relay 改写上游模型")
    await runtime.stopAll()
}
