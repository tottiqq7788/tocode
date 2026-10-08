import Foundation

@MainActor
protocol AppLinkControlling: AnyObject {
    var links: [AppAssociation] { get }
    var relayBaseURL: String { get }
    func beginPairing(role: TogentRole, displayName: String, relay: String) async throws -> String
    func cancelPairing()
    func updateLink(id: String, displayName: String, role: TogentRole) async throws
    func deleteLink(id: String) async throws
    func attach(togent: TogentService)
    func start()
    func stop()
}

@MainActor
final class AppLinkService: AppLinkControlling {
    private let store: AppLinkStore
    private let client: AppLinkConnecting
    private var config: AppRelayConfig
    private var file: AppLinkFile
    private var connection: AppLinkConnection?
    private var togent: TogentService?
    private var didAttach = false
    private var stopped = true
    private var connectTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?
    private var closeWait: CheckedContinuation<Void, Never>?
    private var pendingReplies: [String: CheckedContinuation<Void, Error>] = [:]

    private(set) var links: [AppAssociation]

    var relayBaseURL: String { config.baseURL }
    var didChange: (() -> Void)?
    var onPaired: (() -> Void)?

    init(store: AppLinkStore = AppLinkStore(), client: AppLinkConnecting = URLSessionAppLinkClient()) {
        self.store = store
        self.client = client
        config = store.loadConfig()
        file = store.loadFile()
        links = file.links
    }

    func attach(togent: TogentService) {
        guard !didAttach else { return }
        didAttach = true
        self.togent = togent
        let forward = togent.replyHandler
        togent.replyHandler = { [weak self] job, role, reply in
            if job.channel == .app {
                guard let self else {
                    throw TogentError.unavailable("应用关联已停止")
                }
                try await self.deliver(job: job, reply: reply)
            } else if let forward {
                try await forward(job, role, reply)
            } else {
                throw TogentError.unavailable("微信回复通道未就绪")
            }
        }
    }

    func start() {
        stopped = false
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            await self?.runConnection()
        }
    }

    func stop() {
        stopped = true
        connectTask?.cancel()
        pairingTask?.cancel()
        connection?.close()
        connection = nil
        resumeCloseWait()
    }

    func beginPairing(role: TogentRole, displayName: String, relay: String) async throws -> String {
        guard let base = AppRelayURL.normalized(relay) else {
            throw AppLinkError.invalidURL
        }
        if config.baseURL != base.absoluteString {
            config.deviceID = ""
            config.deviceToken = ""
        }
        config.baseURL = base.absoluteString
        if config.deviceName.isEmpty {
            config.deviceName = Host.current().localizedName ?? "Mac"
        }
        if config.deviceToken.isEmpty {
            let registered = try await client.register(base: base, name: config.deviceName)
            config.deviceID = registered.id
            config.deviceToken = registered.token
        }
        try store.saveConfig(config)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = name.isEmpty ? role.name : name
        let ticket = try await client.createPairing(
            base: base,
            token: config.deviceToken,
            roleID: role.id.uuidString,
            roleName: role.name,
            displayName: shown
        )
        let payload = AppLinkPairingPayload.make(relay: base, code: ticket.code)
        pairingTask?.cancel()
        pairingTask = Task { [weak self] in
            await self?.watchPairing(base: base, code: ticket.code, role: role, displayName: shown)
        }
        start()
        return payload
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
    }

    func updateLink(id: String, displayName: String, role: TogentRole) async throws {
        guard let index = file.links.firstIndex(where: { $0.id == id }) else {
            throw TogentError.roleNotFound
        }
        guard let base = AppRelayURL.normalized(config.baseURL), !config.deviceToken.isEmpty else {
            throw AppLinkError.offline
        }
        let shown = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = shown.isEmpty ? role.name : shown
        try await client.updateLink(
            base: base,
            token: config.deviceToken,
            linkID: id,
            roleID: role.id.uuidString,
            roleName: role.name,
            displayName: name
        )
        file.links[index].displayName = name
        file.links[index].roleID = role.id
        file.links[index].roleName = role.name
        try store.saveFile(file)
        links = file.links
        didChange?()
    }

    func deleteLink(id: String) async throws {
        file.links.removeAll { $0.id == id }
        if !file.pendingUnlinks.contains(id) {
            file.pendingUnlinks.append(id)
        }
        try store.saveFile(file)
        links = file.links
        didChange?()
        await flushUnlinks()
    }

    func bind(_ connection: AppLinkConnection) {
        self.connection = connection
        connection.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }
    }

    private func watchPairing(base: URL, code: String, role: TogentRole, displayName: String) async {
        let deadline = Date().addingTimeInterval(180)
        while !Task.isCancelled, Date() < deadline {
            do {
                let snapshot = try await client.pairingStatus(
                    base: base,
                    token: config.deviceToken,
                    code: code
                )
                if snapshot.status == "redeemed", let raw = snapshot.link, let id = raw["link_id"] {
                    let link = AppAssociation(
                        id: id,
                        roleID: role.id,
                        roleName: role.name,
                        displayName: raw["display_name"] ?? displayName,
                        androidID: raw["android_id"] ?? "",
                        androidName: raw["android_name"] ?? "",
                        macName: raw["device_name"] ?? config.deviceName
                    )
                    if !file.links.contains(where: { $0.id == id }) {
                        file.links.append(link)
                        try? store.saveFile(file)
                        links = file.links
                        didChange?()
                        onPaired?()
                    }
                    return
                }
                if snapshot.status == "expired" {
                    return
                }
            } catch {
                if Task.isCancelled { return }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func runConnection() async {
        await flushUnlinks()
        while !stopped {
            guard let base = AppRelayURL.normalized(config.baseURL), !config.deviceToken.isEmpty else {
                return
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                closeWait = continuation
                connection = client.connect(base: base, token: config.deviceToken) { [weak self] event in
                    Task { @MainActor in
                        self?.handle(event)
                    }
                }
            }
            if stopped { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func handle(_ event: AppSocketEvent) {
        switch event {
        case .ready, .reply:
            break
        case .inbound(let linkID, let messageID, let text, let androidID):
            guard let link = links.first(where: { $0.id == linkID }) else { return }
            store.appendHistory(linkID: linkID, text: text, outgoing: false)
            try? togent?.stageAppText(
                linkID: linkID,
                androidID: androidID.isEmpty ? link.androidID : androidID,
                roleID: link.roleID,
                text: text,
                messageID: messageID
            )
        case .accepted(let messageID):
            pendingReplies.removeValue(forKey: messageID)?.resume()
        case .failure(let messageID, let code, _):
            let error = AppLinkError.rejected(code)
            if let waiter = pendingReplies.removeValue(forKey: messageID) {
                waiter.resume(throwing: error)
            }
        case .closed:
            connection = nil
            resumeCloseWait()
            let error = AppLinkError.offline
            let waiters = pendingReplies
            pendingReplies.removeAll()
            for waiter in waiters.values {
                waiter.resume(throwing: error)
            }
        }
    }

    private func deliver(job: TogentJob, reply: TogentReply) async throws {
        let text = reply.text.isEmpty ? "本期只转发文字。" : reply.text
        guard let connection else { throw AppLinkError.offline }
        let messageID = UUID().uuidString
        store.appendHistory(linkID: job.contextToken, text: text, outgoing: true)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pendingReplies[messageID] = continuation
            connection.send([
                "op": "reply",
                "link_id": job.contextToken,
                "message_id": messageID,
                "text": text
            ])
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if let waiter = self.pendingReplies.removeValue(forKey: messageID) {
                    waiter.resume(throwing: AppLinkError.timeout)
                }
            }
        }
    }

    private func flushUnlinks() async {
        guard let base = AppRelayURL.normalized(config.baseURL), !config.deviceToken.isEmpty else {
            return
        }
        var remaining: [String] = []
        for id in file.pendingUnlinks {
            do {
                try await client.deleteLink(base: base, token: config.deviceToken, linkID: id)
            } catch {
                remaining.append(id)
            }
        }
        file.pendingUnlinks = remaining
        try? store.saveFile(file)
    }

    private func resumeCloseWait() {
        let waiter = closeWait
        closeWait = nil
        waiter?.resume()
    }
}
