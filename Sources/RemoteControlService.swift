import Foundation
import Darwin

enum ScreenLock {
    static func lock() -> Bool {
        let paths = [
            "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
            "/System/Library/PrivateFrameworks/login.framework/login",
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            defer { dlclose(handle) }
            guard let symbol = dlsym(handle, "SACLockScreenImmediate") else { continue }
            unsafeBitCast(symbol, to: (@convention(c) () -> Void).self)()
            return true
        }
        return false
    }
}

private func inboundFlag(_ value: Any?) -> Bool? {
    switch value {
    case let flag as Bool:
        return flag
    case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
        return number.boolValue
    default:
        return nil
    }
}

private struct InboundProjectFile {
    let linkID: String
    let requestID: String
    let name: String
    let size: Int
    let kind: String
    let profile: String
    let projectID: String
    let hold: Bool

    init?(_ message: [String: Any], linkID: String, requestID: String) {
        let holdFlag: Bool
        if message["hold"] != nil {
            guard let flag = inboundFlag(message["hold"]) else { return nil }
            holdFlag = flag
        } else {
            holdFlag = false
        }
        guard message["path"] == nil,
              let name = message["name"] as? String,
              let kind = message["kind"] as? String, kind == "image" || kind == "file",
              let profile = message["profile"] as? String,
              let projectID = message["project_id"] as? String,
              !(message["size"] is Bool),
              let size = (message["size"] as? NSNumber)?.intValue,
              size > 0, size <= PhoneProjectAttachments.byteLimit else {
            return nil
        }
        self.linkID = linkID
        self.requestID = requestID
        self.name = name
        self.size = size
        self.kind = kind
        self.profile = profile
        self.projectID = projectID
        self.hold = holdFlag
    }
}

@MainActor
final class RemoteControlService {
    private let store: RemoteControlStore
    private let transport: RemoteControlTransporting
    private let bindingKeys: BindingKeyStoring
    private let executor: TocodeCommandExecutor
    private let pageWriter: RemoteControlPageWriting
    private let opener: RemoteControlPageOpening
    private let phoneHermes: PhoneHermesRuntime
    private let phoneHermesProfiles: PhoneHermesProfileStore
    private let phoneHermesSessions: PhoneHermesSessionIndex
    private let phoneHermesActivity = PhoneHermesActivity()
    private let showHiddenFiles: () -> Bool
    private let loadDesktops: () -> [DesktopMenuEntry]?
    private let switchSpace: (DesktopSpaceTarget) -> Bool
    private let raiseWindow: (Int32, UInt32) -> Bool
    private let lockScreen: () -> Bool
    var savedButtons: () -> [RemoteButton] = { RemoteButtonStore().all() }
    var runSavedButton: ((RemoteButton) -> (Bool, String))?
    private let pollInterval: TimeInterval
    private var record: RemoteControlRecord
    private var associationTask: Task<Void, Never>?
    private var inboundFile: InboundProjectFile?

    init(
        store: RemoteControlStore,
        transport: RemoteControlTransporting,
        bindingKeys: BindingKeyStoring = KeychainBindingKeyStore(),
        executor: TocodeCommandExecutor,
        pageWriter: RemoteControlPageWriting = RemoteControlPageWriter(),
        opener: RemoteControlPageOpening = WorkspaceRemoteControlPageOpener(),
        phoneHermes: PhoneHermesRuntime = PhoneHermesLiveRuntime(),
        phoneHermesProfiles: PhoneHermesProfileStore = PhoneHermesProfileStore(),
        phoneHermesSessions: PhoneHermesSessionIndex = PhoneHermesSessionIndex(),
        showHiddenFiles: @escaping () -> Bool = { FinderVisibilityService().currentShowAllFiles() },
        loadDesktops: @escaping () -> [DesktopMenuEntry]? = { SystemDesktopWindowCatalog().loadMenu() },
        switchSpace: @escaping (DesktopSpaceTarget) -> Bool = { SystemDesktopSpaceSwitcher().switchToSpace($0) },
        raiseWindow: @escaping (Int32, UInt32) -> Bool = { SystemDesktopSpaceSwitcher().raiseWindow(pid: $0, windowID: $1) },
        lockScreen: @escaping () -> Bool = { ScreenLock.lock() },
        pollInterval: TimeInterval = 2
    ) {
        self.store = store
        self.transport = transport
        self.bindingKeys = bindingKeys
        self.executor = executor
        self.pageWriter = pageWriter
        self.opener = opener
        self.phoneHermes = phoneHermes
        self.phoneHermesProfiles = phoneHermesProfiles
        self.phoneHermesSessions = phoneHermesSessions
        self.showHiddenFiles = showHiddenFiles
        self.loadDesktops = loadDesktops
        self.switchSpace = switchSpace
        self.raiseWindow = raiseWindow
        self.lockScreen = lockScreen
        self.pollInterval = pollInterval
        record = store.load()
        transport.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.handle(message)
            }
        }
        transport.onBinary = { [weak self] data in
            Task { @MainActor in
                self?.acceptProjectFile(data)
            }
        }
    }

    var relayURL: String { record.relayURL }
    var links: [RemoteControlLink] { record.links }
    var isAssociated: Bool { !record.links.isEmpty }
    var hasBindingKey: Bool { record.hasBindingKey }

    func setRelay(_ raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https" || isLocalHTTP(url) else {
            throw URLError(.badURL)
        }
        record.relayURL = trimmed
        record.deviceID = ""
        record.deviceToken = ""
        record.links = []
        try store.save(record)
        DiagnosticLog.shared.event("relay.set", detail: ["host": url.host ?? ""])
        transport.disconnect()
    }

    func start() {
        DiagnosticLog.shared.event("relay.start_service", deviceID: record.deviceID)
        Task { await connectIfPossible() }
    }

    func setBindingKey(_ secret: String) throws {
        let previousSecret = try bindingKeys.loadPlaintext()
        let previousDigest = record.bindingKeyDigest
        try bindingKeys.savePlaintext(secret)
        record.bindingKeyDigest = BindingKeyDigest.hex(of: secret)
        do {
            try store.save(record)
        } catch {
            record.bindingKeyDigest = previousDigest
            if let previousSecret {
                try? bindingKeys.savePlaintext(previousSecret)
            } else {
                try? bindingKeys.deletePlaintext()
            }
            throw error
        }
    }

    func clearBindingKey() throws {
        try bindingKeys.deletePlaintext()
        record.bindingKeyDigest = nil
        try store.save(record)
    }

    func revealBindingKey() throws -> String {
        guard let secret = try bindingKeys.loadPlaintext(), !secret.isEmpty else {
            throw BindingKeyError.notSet
        }
        return secret
    }

    func startAssociation() {
        associationTask?.cancel()
        associationTask = Task { [weak self] in
            await self?.performAssociation()
        }
    }

    private func performAssociation() async {
        do {
            guard let digest = record.bindingKeyDigest, record.hasBindingKey else {
                throw BindingKeyError.notSet
            }
            try await ensureDevice()
            guard let relay = URL(string: record.relayURL) else { throw URLError(.badURL) }
            let pairing = try await transport.createPairing(
                relay: relay,
                token: record.deviceToken,
                bindingKeyDigest: digest
            )
            let payload = RemoteControlPayload.qr(relay: record.relayURL, code: pairing.code)
            let pageURL = try pageWriter.prepare(qrText: payload)
            guard opener.open(pageURL) else {
                throw URLError(.cannotOpenFile)
            }
            let startedAt = Date()
            while !Task.isCancelled && Date().timeIntervalSince(startedAt) < 180 {
                try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                if Task.isCancelled { return }
                guard let status = try? await transport.pairingStatus(
                    relay: relay,
                    token: record.deviceToken,
                    code: pairing.code
                ) else {
                    try? pageWriter.update(.waiting)
                    continue
                }
                if status.status == "redeemed", let link = status.link {
                    if !record.links.contains(where: { $0.linkID == link.linkID }) {
                        record.links.append(link)
                        try? store.save(record)
                    }
                    try? pageWriter.update(.success)
                    associationTask = nil
                    return
                }
                if status.status == "expired" {
                    try? pageWriter.update(.expired)
                    associationTask = nil
                    return
                }
                try? pageWriter.update(.waiting)
            }
            if !Task.isCancelled {
                try? pageWriter.update(.expired)
            }
        } catch is CancellationError {
            return
        } catch {
            try? pageWriter.update(.failed("生成失败。请确认中转地址可访问。"))
        }
        associationTask = nil
    }

    func unlink(_ linkID: String) async {
        guard let relay = URL(string: record.relayURL), !record.deviceToken.isEmpty else { return }
        try? await transport.deleteLink(relay: relay, token: record.deviceToken, linkID: linkID)
        record.links.removeAll { $0.linkID == linkID }
        try? store.save(record)
    }

    func handle(_ message: [String: Any]) {
        let op = message["op"] as? String ?? ""
        if op == "ready" {
            let linkIDs = message["link_ids"] as? [Any] ?? []
            DiagnosticLog.shared.event(
                "peer.ready",
                deviceID: record.deviceID,
                detail: ["link_count": linkIDs.count, "side": message["side"] as? String ?? ""]
            )
            return
        }
        if op == "link_revoked", let linkID = message["link_id"] as? String {
            DiagnosticLog.shared.event("link.revoked", linkID: linkID, deviceID: record.deviceID)
            record.links.removeAll { $0.linkID == linkID }
            try? store.save(record)
            return
        }
        guard let linkID = message["link_id"] as? String,
              let requestID = message["request_id"] as? String,
              record.links.contains(where: { $0.linkID == linkID }) else {
            return
        }
        if op == "app_inbound" {
            let kind = message["kind"] as? String ?? ""
            let sessionID = message["session_id"] as? String ?? ""
            let title = message["title"] as? String ?? ""
            let text = message["text"] as? String ?? ""
            let profile = message["profile"] as? String ?? ""
            let projectID = message["project_id"] as? String ?? ""
            let path = message["path"] as? String ?? ""
            let offset = (message["offset"] as? NSNumber)?.intValue ?? 0
            let cursor = message["cursor"] as? String ?? ""
            DiagnosticLog.shared.event(
                "app.inbound",
                linkID: linkID,
                deviceID: record.deviceID,
                detail: [
                    "kind": kind,
                    "request_id": requestID,
                    "has_path": !path.isEmpty,
                    "has_text": !text.isEmpty,
                ]
            )
            if kind == "download" {
                Task {
                    await replyDownload(
                        linkID: linkID,
                        requestID: requestID,
                        profile: profile,
                        projectID: projectID,
                        text: text
                    )
                }
                return
            }
            let includeHidden = showHiddenFiles()
            let runtime = phoneHermes
            let profiles = phoneHermesProfiles
            let sessions = phoneHermesSessions
            let names = HermesProfileCatalog.names()
            Task {
                let reply = await PhoneHermesApp.handle(
                    kind: kind,
                    sessionID: sessionID,
                    title: title,
                    text: text,
                    runtime: runtime,
                    profile: profile,
                    projectID: projectID,
                    path: path,
                    offset: offset,
                    cursor: cursor,
                    includeHidden: includeHidden,
                    profileStore: profiles,
                    sessionIndex: sessions,
                    catalog: names,
                    activity: phoneHermesActivity,
                    projectsDatabase: { HermesProfileProjects.databasePath(home: NSHomeDirectory(), profile: $0) },
                    isDirectory: { path in
                        var isDir: ObjCBool = false
                        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                    },
                    ensureProfileEnv: { name in
                        let home = HermesProfileCatalog.home(userHome: NSHomeDirectory(), profile: name)
                        var isDir: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: home, isDirectory: &isDir), isDir.boolValue else { return }
                        try HermesGatewayEnv.ensure(at: HermesProfileCatalog.envURL(userHome: NSHomeDirectory(), profile: name))
                    }
                )
                var payload: [String: Any] = [
                    "op": "app_result",
                    "link_id": linkID,
                    "request_id": requestID,
                    "kind": kind,
                    "ok": reply.ok,
                    "text": reply.text
                ]
                if !reply.body.isEmpty {
                    payload["body"] = reply.body
                }
                DiagnosticLog.shared.event(
                    "app.outbound_result",
                    linkID: linkID,
                    deviceID: record.deviceID,
                    detail: [
                        "kind": kind,
                        "request_id": requestID,
                        "ok": reply.ok,
                        "error": reply.ok ? "" : String(reply.text.prefix(80)),
                    ]
                )
                try? await transport.send(payload)
            }
            return
        }
        if op == "project_file_inbound" {
            guard let pending = InboundProjectFile(message, linkID: linkID, requestID: requestID) else {
                replyProjectFile(linkID: linkID, requestID: requestID, ok: false, path: "", text: "文件头无效")
                return
            }
            if let stale = inboundFile {
                replyProjectFile(linkID: stale.linkID, requestID: stale.requestID, ok: false, path: "", text: "文件内容没有收到")
            }
            inboundFile = pending
            return
        }
        if op == "project_file_place" {
            let hold = message["hold_id"] as? String ?? ""
            let profile = message["profile"] as? String ?? ""
            let projectID = message["project_id"] as? String ?? ""
            guard message["path"] == nil, message["name"] == nil else {
                replyProjectFile(linkID: linkID, requestID: requestID, ok: false, path: "", text: "不能指定保存位置")
                return
            }
            let reply = placeHeldFile(linkID: linkID, profile: profile, projectID: projectID, hold: hold)
            let path = reply.body["path"] as? String ?? ""
            replyProjectFile(
                linkID: linkID, requestID: requestID, ok: reply.ok && !path.isEmpty, path: path, text: reply.ok ? "" : reply.text
            )
            return
        }
        if op == "project_file_drop" {
            let hold = message["hold_id"] as? String ?? ""
            let removed = dropHeldFile(linkID: linkID, hold: hold)
            replyProjectFile(
                linkID: linkID, requestID: requestID, ok: removed, path: "", text: removed ? "" : "这份附件已经不在了", dropped: removed
            )
            return
        }
        guard op == "command_inbound" else { return }
        let action = message["action"] as? String ?? ""
        let target = message["target"] as? [String: Any]
        Task {
            let outcome = await self.perform(action: action, target: target)
            var payload: [String: Any] = [
                "op": "result",
                "link_id": linkID,
                "request_id": requestID,
                "ok": outcome.ok,
                "text": outcome.text,
            ]
            if let body = outcome.body {
                payload["body"] = body
            }
            try? await transport.send(payload)
        }
    }

    private func perform(action: String, target: [String: Any]?) async -> (ok: Bool, text: String, body: [String: Any]?) {
        guard let mapped = RemoteControlAction(rawValue: action) else {
            return (false, "动作不在白名单", nil)
        }
        switch mapped {
        case .desktops:
            guard let entries = loadDesktops() else { return (false, "无法读取桌面", nil) }
            return (true, "", PhoneDesktopList.body(entries))
        case .desktopSwitch:
            let entries = loadDesktops() ?? []
            guard let target, let command = PhoneDesktopList.command(entries: entries, target: target) else {
                return (false, "这个桌面或窗口已经不在了", nil)
            }
            guard switchSpace(command.spaceTarget) else {
                return (false, "系统没有切到所选桌面。", nil)
            }
            guard DesktopWindowActivation.shouldRaise(switched: true, command: command) else {
                return (true, "已切换", nil)
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard case .window(_, let windowID, let pid) = command else {
                return (true, "已切换", nil)
            }
            if raiseWindow(pid, windowID) {
                return (true, "已切换到该窗口", nil)
            }
            return (true, "桌面已经切换，但无法把窗口带到前台。请在系统设置的辅助功能里允许 Tocode。", nil)
        case .remoteButtons:
            return (true, "", RemoteButtonCatalog.body(savedButtons()))
        case .remotePress:
            guard let button = RemoteButtonCatalog.resolve(savedButtons(), target: target) else {
                return (false, "这个按钮已经不在了", nil)
            }
            let outcome = savedButtonOutcome(button)
            return (outcome.0, outcome.1, nil)
        }
    }

    private func savedButtonOutcome(_ button: RemoteButton) -> (Bool, String) {
        switch button.target {
        case .status:
            switch executor.execute("status") {
            case .success(let output):
                return (true, output.text)
            case .failure(let error):
                return (false, error.localizedDescription)
            }
        case .dismissBlackout:
            guard executor.remoteBlackoutPresented else { return (false, "现在没有黑屏") }
            executor.dismissRemoteBlackout()
            return (true, "已取消黑屏")
        case .lock:
            return lockScreen() ? (true, "已锁定屏幕") : (false, "无法锁定屏幕")
        case .mapped:
            return runSavedButton?(button) ?? (false, "无法执行")
        }
    }

    private func ensureDevice() async throws {
        guard record.deviceToken.isEmpty else {
            await connectIfPossible()
            return
        }
        guard let relay = URL(string: record.relayURL) else { throw URLError(.badURL) }
        let created = try await transport.register(relay: relay, name: Host.current().localizedName ?? "Mac")
        record.deviceID = created.id
        record.deviceToken = created.token
        try store.save(record)
        DiagnosticLog.shared.event("device.registered", deviceID: record.deviceID, detail: ["host": relay.host ?? ""])
        try await transport.connect(relay: relay, token: record.deviceToken)
    }

    private func connectIfPossible() async {
        guard !record.deviceToken.isEmpty, let relay = URL(string: record.relayURL) else { return }
        DiagnosticLog.shared.event("ws.connect_if_possible", deviceID: record.deviceID, detail: ["host": relay.host ?? ""])
        try? await transport.connect(relay: relay, token: record.deviceToken)
    }

    private func acceptProjectFile(_ data: Data) {
        guard let pending = inboundFile else { return }
        inboundFile = nil
        guard data.count == pending.size, data.count <= PhoneProjectAttachments.byteLimit else {
            replyProjectFile(linkID: pending.linkID, requestID: pending.requestID, ok: false, path: "", text: "文件长度不匹配")
            return
        }
        if pending.hold {
            let reply = holdIncomingFile(pending, bytes: data)
            let hold = reply.body["hold_id"] as? String ?? ""
            let path = reply.body["path"] as? String ?? ""
            replyProjectFile(
                linkID: pending.linkID, requestID: pending.requestID, ok: reply.ok && !hold.isEmpty && !path.isEmpty,
                path: path, text: reply.ok ? "" : reply.text, hold: hold
            )
            return
        }
        let reply = PhoneHermesApp.saveAttachment(
            profile: pending.profile,
            projectID: pending.projectID,
            name: pending.name,
            kind: pending.kind,
            bytes: data,
            catalog: HermesProfileCatalog.names(),
            profileStore: phoneHermesProfiles,
            projectsDatabase: { HermesProfileProjects.databasePath(home: NSHomeDirectory(), profile: $0) },
            isDirectory: { path in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }
        )
        let path = reply.body["path"] as? String ?? ""
        replyProjectFile(
            linkID: pending.linkID,
            requestID: pending.requestID,
            ok: reply.ok && !path.isEmpty,
            path: path,
            text: reply.ok ? "" : reply.text
        )
    }

    private func holdIncomingFile(_ pending: InboundProjectFile, bytes: Data) -> PhoneHermesAppReply {
        PhoneHermesApp.holdAttachment(
            linkID: pending.linkID,
            profile: pending.profile,
            projectID: pending.projectID,
            name: pending.name,
            kind: pending.kind,
            bytes: bytes,
            catalog: HermesProfileCatalog.names(),
            profileStore: phoneHermesProfiles,
            projectsDatabase: { HermesProfileProjects.databasePath(home: NSHomeDirectory(), profile: $0) },
            isDirectory: { path in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }
        )
    }

    private func placeHeldFile(linkID: String, profile: String, projectID: String, hold: String) -> PhoneHermesAppReply {
        PhoneHermesApp.placeHeldAttachment(
            linkID: linkID,
            profile: profile,
            projectID: projectID,
            hold: hold,
            catalog: HermesProfileCatalog.names(),
            profileStore: phoneHermesProfiles,
            projectsDatabase: { HermesProfileProjects.databasePath(home: NSHomeDirectory(), profile: $0) },
            isDirectory: { path in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }
        )
    }

    private func dropHeldFile(linkID: String, hold: String) -> Bool {
        PhoneHermesApp.dropHeldAttachment(linkID: linkID, hold: hold)
    }

    private func replyDownload(linkID: String, requestID: String, profile: String, projectID: String, text: String) async {
        func fail(_ message: String) async {
            try? await transport.send([
                "op": "app_result",
                "link_id": linkID,
                "request_id": requestID,
                "kind": "download",
                "ok": false,
                "text": message,
            ])
        }
        let snapshot = await phoneHermes.snapshot()
        guard snapshot.installed else {
            await fail(PhoneHermesApp.missingHermes)
            return
        }
        guard let relatives = PhoneHermesApp.downloadRelatives(from: text) else {
            await fail("下载列表无效")
            return
        }
        let names = HermesProfileCatalog.names()
        let active = HermesProfileCatalog.accepted(
            profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? phoneHermesProfiles.resolved(among: names)
                : profile,
            among: names
        )
        guard let project = PhoneHermesApp.ownedProject(
            projectID,
            profile: active,
            database: { HermesProfileProjects.databasePath(home: NSHomeDirectory(), profile: $0) }
        ) else {
            await fail(PhoneHermesApp.needProject)
            return
        }
        let root = project.rootPath
        let pack = await Task.detached(priority: .userInitiated) {
            PhoneHermesDirectory.packDownload(root: root, relatives: relatives)
        }.value
        switch pack {
        case .failure(let message):
            await fail(message)
        case .success(let name, let mode, let data):
            do {
                try await transport.send([
                    "op": "file_reply",
                    "link_id": linkID,
                    "message_id": requestID,
                    "name": name,
                    "size": data.count,
                    "kind": "file",
                    "text": mode,
                ])
                try await transport.sendBytes(data)
                try await transport.send([
                    "op": "app_result",
                    "link_id": linkID,
                    "request_id": requestID,
                    "kind": "download",
                    "ok": true,
                    "text": "",
                    "body": ["mode": mode, "name": name],
                ])
            } catch {
                await fail("发送失败")
            }
        }
    }

    private func replyProjectFile(
        linkID: String, requestID: String, ok: Bool, path: String, text: String, hold: String = "", dropped: Bool = false
    ) {
        var payload: [String: Any] = [
            "op": "project_file_result",
            "link_id": linkID,
            "request_id": requestID,
            "ok": ok,
            "text": text,
        ]
        if ok, !path.isEmpty {
            payload["path"] = path
        }
        if ok, !hold.isEmpty {
            payload["hold_id"] = hold
        }
        if ok, dropped {
            payload["dropped"] = true
        }
        let transport = self.transport
        Task { try? await transport.send(payload) }
    }

    private func isLocalHTTP(_ url: URL) -> Bool {
        guard url.scheme == "http" else { return false }
        let host = url.host ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
