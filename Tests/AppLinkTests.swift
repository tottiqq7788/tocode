import Darwin
import Foundation

private final class ScriptedConnection: AppLinkConnection, @unchecked Sendable {
    var onEvent: ((AppSocketEvent) -> Void)?
    private(set) var sent: [[String: String]] = []

    func send(_ payload: [String: String]) {
        sent.append(payload)
        guard let id = payload["message_id"] else { return }
        Task { @MainActor in
            self.onEvent?(.accepted(messageID: id))
        }
    }

    func close() {}

    func emit(_ event: AppSocketEvent) {
        onEvent?(event)
    }
}

func testAppLinkPayloadStoreAndMenuWords() {
    let relay = AppRelayURL.normalized("http://127.0.0.1:8787")
    let payload = AppLinkPairingPayload.make(relay: relay!, code: "ABCD2345")
    expect(payload.hasPrefix("tocode-app://pair?"), "配对二维码使用应用配对协议")
    expect(!payload.contains("SECRET_PROMPT"), "二维码不含角色提示词")
    let parsed = AppLinkPairingPayload.parse(payload)
    expect(parsed?.code == "ABCD2345", "配对码可以还原")
    expect(parsed?.relay.host == "127.0.0.1", "配对码带中转地址")
    expect(AppRelayURL.normalized("http://example.com") == nil, "公网地址必须使用 https")
    expect(AppLinkPairingPayload.parse("https://example.com/secret") == nil, "无关地址不能当配对码")

    let root = makeTogentTemporaryDirectory("app-link-store")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppLinkStore(directory: root)
    var file = AppLinkFile()
    file.links = [
        AppAssociation(
            id: "link-1",
            roleID: UUID(),
            roleName: "alpha",
            displayName: "Alpha",
            androidID: "phone",
            androidName: "Pixel",
            macName: "Mac"
        )
    ]
    try! store.saveFile(file)
    store.appendHistory(linkID: "link-1", text: "留下的话", outgoing: false)
    file.links = []
    try! store.saveFile(file)
    let history = store.historyURL(linkID: "link-1")
    let saved = (try? String(contentsOf: history, encoding: .utf8)) ?? ""
    expect(saved.contains("留下的话"), "删除关联后本机历史仍在")
    let mode = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("app-links.json").path)[
        .posixPermissions
    ] as? NSNumber)?.intValue
    expect(mode == 0o600, "应用关联文件权限为 0600")
    let historyMode = (try? FileManager.default.attributesOfItem(atPath: history.path)[
        .posixPermissions
    ] as? NSNumber)?.intValue
    expect(historyMode == 0o600, "应用关联历史权限为 0600")

    expect(
        [
            TogentMenuLayout.root,
            TogentMenuLayout.channels,
            TogentMenuLayout.weChatAssociation,
            TogentMenuLayout.appAssociations,
            TogentMenuLayout.addAssociation,
            TogentMenuLayout.roles
        ] == ["togent", "频道", "微信关联", "应用关联", "新增…", "角色"],
        "菜单词条是 togent、频道、微信关联、应用关联和角色"
    )
    let mapped = KeyboardMappingAction.allCases.map(\.title).joined(separator: "\n")
    expect(!mapped.contains("绑定") && !mapped.contains("扫码") && !mapped.contains("应用关联"),
           "键盘映射不出现绑定或扫码")
    let manual = UserManual.pages.map(\.body).joined(separator: "\n")
    expect(manual.contains("应用关联") && manual.contains("微信关联"), "说明书写明频道里的两种关联")
    expect(manual.contains("总切换") == false || manual.contains("应用关联"), "说明书覆盖应用关联")
}

@MainActor
func testAppChannelStaysOutOfWeChat() async {
    let root = makeTogentTemporaryDirectory("app-channel")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TogentStore(databaseURL: root.appendingPathComponent("togent.sqlite"))
    let runtime = StubTogentRuntime()
    runtime.result = .success("回到安卓")
    let models = [TogentModelOption(publishedModelID: "model-a", providerName: "厂家")]
    let togent = TogentService(
        store: store,
        workspace: TogentWorkspaceService(homeDirectory: root),
        runtime: runtime,
        availableModelOptions: { models },
        bootstrapDefaultRole: false
    )
    var activeDraft = togent.newRoleDraft()
    activeDraft.name = "ActiveRole"
    activeDraft.publishedModelID = "model-a"
    activeDraft.isActive = true
    let active = try! togent.createRole(from: activeDraft)
    var linkedDraft = togent.newRoleDraft()
    linkedDraft.name = "LinkedRole"
    linkedDraft.publishedModelID = "model-a"
    linkedDraft.prompt = "SECRET_PROMPT"
    linkedDraft.isActive = false
    let linked = try! togent.createRole(from: linkedDraft)
    expect(active.isActive && !linked.isActive, "应用关联可以指向未激活角色")

    var wechatReplies = 0
    togent.replyHandler = { _, _, _ in
        wechatReplies += 1
    }
    let links = AppLinkService(store: AppLinkStore(directory: root.appendingPathComponent("links")))
    let connection = ScriptedConnection()
    links.attach(togent: togent)
    links.bind(connection)
    try! togent.stageAppText(
        linkID: "link-9",
        androidID: "phone-9",
        roleID: linked.id,
        text: ".help",
        messageID: "msg-1"
    )
    let arrived = await waitForTogentCondition {
        !connection.sent.isEmpty
    }
    expect(arrived, "app 文字进入锁定角色并产生回复")
    let prompt = runtime.executions.first?.1 ?? ""
    expect(prompt.contains("SECRET_PROMPT"), "app 任务正文带当前角色提示词")
    expect(prompt.contains(".help"), "应用文字原文进入任务，不按微信命令吃掉")
    expect(prompt.contains("不要按微信命令解析"), "app 任务明确不是微信命令")
    expect(!prompt.contains("<tocode_wechat_files>"), "app 任务不要求微信文件控制块")
    expect(wechatReplies == 0, "app 回复不走微信发送")
    expect(connection.sent.contains { $0["text"] == "回到安卓" && $0["link_id"] == "link-9" },
           "回复只发回这条关联")
    let job = try! store.jobs().first { $0.deduplicationKey == "app:link-9:msg-1" }
    expect(job?.channel == .app && job?.roleID == linked.id, "任务通道是 app 且角色是关联锁定的那个")

    connection.emit(.inbound(linkID: "missing", messageID: "msg-2", text: "不该进", androidID: "phone-9"))
    try? await Task.sleep(nanoseconds: 100_000_000)
    expect(try! store.jobs().contains { $0.deduplicationKey == "app:missing:msg-2" } == false,
           "已删除或未知关联不再入队")

    let wechatJob = TogentJob(
        id: UUID(),
        deduplicationKey: "wx",
        roleID: active.id,
        fromUserID: "user",
        contextToken: "ctx",
        messageText: "微信",
        receivedAt: Date(),
        state: .running,
        attemptCount: 1,
        lastError: nil,
        createdAt: Date(),
        updatedAt: Date(),
        channel: .wechat
    )
    try? await togent.replyHandler?(wechatJob, active, TogentReply(text: "微信回复"))
    expect(wechatReplies == 1, "微信任务仍走原来的回复")
}

@MainActor
func testAppLinkRelayRoundTrip() async {
    let root = makeTogentTemporaryDirectory("relay-round")
    defer { try? FileManager.default.removeItem(at: root) }
    let data = root.appendingPathComponent("routes.json")
    guard let launched = launchRelay(data: data) else {
        expect(false, "本机中转应能启动")
        return
    }
    defer { launched.process.terminate() }
    let base = AppRelayURL.normalized("http://127.0.0.1:\(launched.port)")!
    let client = URLSessionAppLinkClient()
    do {
        let device = try await client.register(base: base, name: "Mac")
        let pairing = try await client.createPairing(
            base: base,
            token: device.token,
            roleID: "role-1",
            roleName: "alpha",
            displayName: "Alpha"
        )
        let payload = AppLinkPairingPayload.make(relay: base, code: pairing.code)
        expect(!payload.contains("SECRET_PROMPT"), "真实配对载荷不含提示词")
        let redeemed = try await client.redeemForTest(
            base: base,
            code: pairing.code,
            androidID: "phone-1",
            androidName: "Pixel"
        )
        let macEvents = EventLog()
        let phoneEvents = EventLog()
        let mac = client.connect(base: base, token: device.token) { macEvents.add($0) }
        let phone = client.connect(base: base, token: redeemed.token) { phoneEvents.add($0) }
        defer {
            mac.close()
            phone.close()
        }
        let ready = await waitForTogentCondition {
            macEvents.containsReady && phoneEvents.containsReady
        }
        expect(ready, "Mac 和安卓都连上中转")
        phone.send([
            "op": "text",
            "link_id": redeemed.linkID,
            "message_id": "m-round",
            "text": "round-trip-body"
        ])
        let inbound = await waitForTogentCondition {
            macEvents.texts.contains("round-trip-body")
        }
        expect(inbound, "安卓文字到达 Mac")
        mac.send([
            "op": "reply",
            "link_id": redeemed.linkID,
            "message_id": "r-round",
            "text": "round-trip-reply"
        ])
        let reply = await waitForTogentCondition {
            phoneEvents.texts.contains("round-trip-reply")
        }
        expect(reply, "Mac 回复回到发起的安卓")
        let raw = (try? String(contentsOf: data, encoding: .utf8)) ?? ""
        expect(!raw.contains("round-trip-body") && !raw.contains("SECRET_PROMPT"),
               "中转路由文件不保存消息正文或角色提示词")
    } catch {
        expect(false, "中转往返失败：\(error.localizedDescription)")
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AppSocketEvent] = []

    func add(_ event: AppSocketEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var containsReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return events.contains { if case .ready = $0 { return true }; return false }
    }

    var texts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap { event in
            switch event {
            case .inbound(_, _, let text, _):
                return text
            case .reply(_, _, let text):
                return text
            default:
                return nil
            }
        }
    }
}

private struct RelayProcess {
    let process: Process
    let port: Int
}

private func launchRelay(data: URL) -> RelayProcess? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("../relay/server.py")
    guard FileManager.default.fileExists(atPath: script.path) else { return nil }
    process.arguments = [script.path, "--host", "127.0.0.1", "--port", "0", "--data", data.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }
    let fd = pipe.fileHandleForReading.fileDescriptor
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    let deadline = Date().addingTimeInterval(5)
    var buffer = ""
    while Date() < deadline {
        var bytes = [UInt8](repeating: 0, count: 512)
        let count = read(fd, &bytes, bytes.count)
        if count > 0 {
            buffer += String(decoding: bytes.prefix(count), as: UTF8.self)
            if let line = buffer.split(separator: "\n").first(where: { $0.hasPrefix("READY ") }) {
                let parts = line.split(separator: " ")
                if parts.count >= 3, let port = Int(parts[2]) {
                    return RelayProcess(process: process, port: port)
                }
            }
        }
        usleep(20_000)
    }
    process.terminate()
    return nil
}

extension URLSessionAppLinkClient {
    func redeemForTest(
        base: URL,
        code: String,
        androidID: String,
        androidName: String
    ) async throws -> (linkID: String, token: String) {
        var request = URLRequest(url: AppRelayURL.endpoint(base, path: "/v1/pairings/\(code)/redeem")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "android_id": androidID,
            "android_name": androidName
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard status == 200,
              let linkID = body["link_id"] as? String,
              let token = body["link_token"] as? String else {
            throw AppLinkError.rejected(body["error"] as? String ?? "http_\(status)")
        }
        return (linkID, token)
    }
}
