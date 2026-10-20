import Foundation

@MainActor
final class RemoteControlService {
    private let store: RemoteControlStore
    private let transport: RemoteControlTransporting
    private let executor: TocodeCommandExecutor
    private let pageWriter: RemoteControlPageWriting
    private let opener: RemoteControlPageOpening
    private let phoneHermes: PhoneHermesRuntime
    private let phoneHermesPath: PhoneHermesPathStore
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
        phoneHermesPath: PhoneHermesPathStore = PhoneHermesPathStore(),
        pollInterval: TimeInterval = 2
    ) {
        self.store = store
        self.transport = transport
        self.executor = executor
        self.pageWriter = pageWriter
        self.opener = opener
        self.phoneHermes = phoneHermes
        self.phoneHermesPath = phoneHermesPath
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
            let directory = phoneHermesPath.configuredDirectory()
            let runtime = phoneHermes
            Task {
                let reply = await PhoneHermesApp.handle(
                    kind: kind,
                    sessionID: sessionID,
                    title: title,
                    text: text,
                    directory: directory,
                    runtime: runtime
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
        let outcome: (Bool, String)
        if let mapped = RemoteControlAction(rawValue: action) {
            switch executor.execute(mapped.commandBody) {
            case .success(let output):
                outcome = (true, output.text)
            case .failure(let error):
                outcome = (false, error.localizedDescription)
            }
        } else {
            outcome = (false, "动作不在白名单")
        }
        Task {
            try? await transport.send([
                "op": "result",
                "link_id": linkID,
                "request_id": requestID,
                "ok": outcome.0,
                "text": outcome.1
            ])
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
