import Foundation

protocol RemoteControlTransporting: AnyObject {
    func register(relay: URL, name: String) async throws -> (id: String, token: String)
    func createPairing(relay: URL, token: String, bindingKeyDigest: String) async throws -> (code: String, expiresAt: Int)
    func pairingStatus(relay: URL, token: String, code: String) async throws -> (status: String, link: RemoteControlLink?)
    func deleteLink(relay: URL, token: String, linkID: String) async throws
    func connect(relay: URL, token: String) async throws
    func send(_ object: [String: Any]) async throws
    func disconnect()
    var onMessage: (([String: Any]) -> Void)? { get set }
    var onBinary: ((Data) -> Void)? { get set }
}

final class RemoteControlHTTPClient: RemoteControlTransporting {
    var onMessage: (([String: Any]) -> Void)?
    var onBinary: ((Data) -> Void)?
    private var task: URLSessionWebSocketTask?
    private var socketURL: URL?
    private var retryDelay: TimeInterval = RemoteControlHTTPClient.retryStart
    private var pingAnswered = true
    private let lock = NSLock()
    private let session = URLSession(configuration: .default)

    private static let retryStart: TimeInterval = 1
    private static let retryMax: TimeInterval = 30
    private static let pingInterval: TimeInterval = 25

    func register(relay: URL, name: String) async throws -> (id: String, token: String) {
        let body = try await request(relay.appendingPathComponent("v1/devices"), method: "POST", token: nil, json: ["name": name])
        return (body["device_id"] as? String ?? "", body["device_token"] as? String ?? "")
    }

    func createPairing(relay: URL, token: String, bindingKeyDigest: String) async throws -> (code: String, expiresAt: Int) {
        let body = try await request(
            relay.appendingPathComponent("v1/pairings"),
            method: "POST",
            token: token,
            json: ["binding_key_digest": bindingKeyDigest]
        )
        return (body["code"] as? String ?? "", body["expires_at"] as? Int ?? 0)
    }

    func pairingStatus(relay: URL, token: String, code: String) async throws -> (status: String, link: RemoteControlLink?) {
        let body = try await request(
            relay.appendingPathComponent("v1/pairings/\(code)"),
            method: "GET",
            token: token,
            json: nil
        )
        let status = body["status"] as? String ?? "pending"
        guard let raw = body["link"] as? [String: Any],
              let id = raw["link_id"] as? String else {
            return (status, nil)
        }
        return (status, RemoteControlLink(
            linkID: id,
            androidID: raw["android_id"] as? String ?? "",
            androidName: raw["android_name"] as? String ?? "Android"
        ))
    }

    func deleteLink(relay: URL, token: String, linkID: String) async throws {
        _ = try await request(relay.appendingPathComponent("v1/links/\(linkID)"), method: "DELETE", token: token, json: nil)
    }

    func connect(relay: URL, token: String) async throws {
        var parts = URLComponents(url: relay, resolvingAgainstBaseURL: false)
        parts?.scheme = relay.scheme == "http" ? "ws" : "wss"
        parts?.path = "/v1/ws"
        parts?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = parts?.url else { throw URLError(.badURL) }
        start(url)
    }

    private func start(_ url: URL) {
        lock.lock()
        socketURL = url
        retryDelay = Self.retryStart
        lock.unlock()
        open(url)
    }

    func send(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        try await current()?.send(.string(text))
    }

    func disconnect() {
        lock.lock()
        let old = task
        task = nil
        socketURL = nil
        lock.unlock()
        old?.cancel(with: .goingAway, reason: nil)
    }

    private func current() -> URLSessionWebSocketTask? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    private func open(_ url: URL) {
        let next = session.webSocketTask(with: url)
        next.maximumMessageSize = PhoneProjectAttachments.byteLimit
        lock.lock()
        let old = task
        task = next
        pingAnswered = true
        lock.unlock()
        old?.cancel(with: .goingAway, reason: nil)
        next.resume()
        receiveLoop(next)
        keepAlive(next)
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.lock.lock()
                self.retryDelay = Self.retryStart
                self.lock.unlock()
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.onMessage?(object)
                    }
                case .data(let data):
                    self.onBinary?(data)
                @unknown default:
                    break
                }
                self.receiveLoop(task)
            case .failure:
                self.reconnect(after: task)
            }
        }
    }

    private func reconnect(after failed: URLSessionWebSocketTask) {
        lock.lock()
        guard task === failed, let url = socketURL else {
            lock.unlock()
            return
        }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, Self.retryMax)
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillFailed = self.task === failed && self.socketURL == url
            self.lock.unlock()
            if stillFailed { self.open(url) }
        }
    }

    private func keepAlive(_ watched: URLSessionWebSocketTask) {
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.pingInterval) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let live = self.task === watched
            let answered = self.pingAnswered
            self.pingAnswered = false
            self.lock.unlock()
            guard live else { return }
            guard answered else {
                watched.cancel(with: .abnormalClosure, reason: nil)
                return
            }
            watched.sendPing { [weak self] error in
                guard let self, error == nil else { return }
                self.lock.lock()
                if self.task === watched { self.pingAnswered = true }
                self.lock.unlock()
            }
            self.keepAlive(watched)
        }
    }

    private func request(_ url: URL, method: String, token: String?, json: [String: Any]?) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
