import Foundation

protocol RemoteControlTransporting: AnyObject {
    func register(relay: URL, name: String) async throws -> (id: String, token: String)
    func createPairing(relay: URL, token: String) async throws -> (code: String, expiresAt: Int)
    func pairingStatus(relay: URL, token: String, code: String) async throws -> (status: String, link: RemoteControlLink?)
    func deleteLink(relay: URL, token: String, linkID: String) async throws
    func connect(relay: URL, token: String) async throws
    func send(_ object: [String: Any]) async throws
    func disconnect()
    var onMessage: (([String: Any]) -> Void)? { get set }
}

final class RemoteControlHTTPClient: RemoteControlTransporting {
    var onMessage: (([String: Any]) -> Void)?
    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)

    func register(relay: URL, name: String) async throws -> (id: String, token: String) {
        let body = try await request(relay.appendingPathComponent("v1/devices"), method: "POST", token: nil, json: ["name": name])
        return (body["device_id"] as? String ?? "", body["device_token"] as? String ?? "")
    }

    func createPairing(relay: URL, token: String) async throws -> (code: String, expiresAt: Int) {
        let body = try await request(relay.appendingPathComponent("v1/pairings"), method: "POST", token: token, json: [:])
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
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop(task)
    }

    func send(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        try await task?.send(.string(text))
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            if case .success(.string(let text)) = result,
               let data = text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.onMessage?(object)
            }
            if case .failure = result { return }
            self.receiveLoop(task)
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
