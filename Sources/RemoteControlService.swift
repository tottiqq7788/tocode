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

@MainActor
final class RemoteControlService {
    private let store: RemoteControlStore
    private let transport: RemoteControlTransporting
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

    init(
        store: RemoteControlStore,
        transport: RemoteControlTransporting,
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
    }

    var relayURL: String { record.relayURL }
    var links: [RemoteControlLink] { record.links }
    var isAssociated: Bool { !record.links.isEmpty }

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
        transport.disconnect()
    }

    func start() {
        Task { await connectIfPossible() }
    }

    func startAssociation() {
        associationTask?.cancel()
        associationTask = Task { [weak self] in
            await self?.performAssociation()
        }
    }

    private func performAssociation() async {
        do {
            try await ensureDevice()
            guard let relay = URL(string: record.relayURL) else { throw URLError(.badURL) }
            let pairing = try await transport.createPairing(relay: relay, token: record.deviceToken)
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
        if op == "link_revoked", let linkID = message["link_id"] as? String {
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
                try? await transport.send(payload)
            }
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
        try await transport.connect(relay: relay, token: record.deviceToken)
    }

    private func connectIfPossible() async {
        guard !record.deviceToken.isEmpty, let relay = URL(string: record.relayURL) else { return }
        try? await transport.connect(relay: relay, token: record.deviceToken)
    }

    private func isLocalHTTP(_ url: URL) -> Bool {
        guard url.scheme == "http" else { return false }
        let host = url.host ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
