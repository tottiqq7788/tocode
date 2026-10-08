import Foundation

protocol AppLinkConnection: AnyObject {
    var onEvent: ((AppSocketEvent) -> Void)? { get set }
    func send(_ payload: [String: String])
    func close()
}

protocol AppLinkConnecting: AnyObject {
    func register(base: URL, name: String) async throws -> (id: String, token: String)
    func createPairing(
        base: URL,
        token: String,
        roleID: String,
        roleName: String,
        displayName: String
    ) async throws -> (code: String, expiresAt: Int)
    func pairingStatus(
        base: URL,
        token: String,
        code: String
    ) async throws -> (status: String, link: [String: String]?)
    func updateLink(
        base: URL,
        token: String,
        linkID: String,
        roleID: String,
        roleName: String,
        displayName: String
    ) async throws
    func deleteLink(base: URL, token: String, linkID: String) async throws
    func connect(
        base: URL,
        token: String,
        onEvent: @escaping (AppSocketEvent) -> Void
    ) -> AppLinkConnection
}

final class URLSessionAppLinkClient: AppLinkConnecting {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func register(base: URL, name: String) async throws -> (id: String, token: String) {
        let body = try await request(
            method: "POST",
            url: try endpoint(base, "/v1/devices"),
            token: nil,
            json: ["name": name]
        )
        guard let id = body["device_id"] as? String,
              let token = body["device_token"] as? String,
              !id.isEmpty, !token.isEmpty else {
            throw AppLinkError.rejected("bad_device")
        }
        return (id, token)
    }

    func createPairing(
        base: URL,
        token: String,
        roleID: String,
        roleName: String,
        displayName: String
    ) async throws -> (code: String, expiresAt: Int) {
        let body = try await request(
            method: "POST",
            url: try endpoint(base, "/v1/pairings"),
            token: token,
            json: [
                "role_id": roleID,
                "role_name": roleName,
                "display_name": displayName
            ]
        )
        guard let code = body["code"] as? String, !code.isEmpty else {
            throw AppLinkError.rejected("bad_code")
        }
        let expires = body["expires_at"] as? Int ?? 0
        return (code, expires)
    }

    func pairingStatus(
        base: URL,
        token: String,
        code: String
    ) async throws -> (status: String, link: [String: String]?) {
        let body = try await request(
            method: "GET",
            url: try endpoint(base, "/v1/pairings/\(code)"),
            token: token,
            json: nil
        )
        let status = body["status"] as? String ?? ""
        let link = (body["link"] as? [String: Any])?.compactMapValues { $0 as? String }
        return (status, link)
    }

    func updateLink(
        base: URL,
        token: String,
        linkID: String,
        roleID: String,
        roleName: String,
        displayName: String
    ) async throws {
        _ = try await request(
            method: "PATCH",
            url: try endpoint(base, "/v1/links/\(linkID)"),
            token: token,
            json: [
                "role_id": roleID,
                "role_name": roleName,
                "display_name": displayName
            ]
        )
    }

    func deleteLink(base: URL, token: String, linkID: String) async throws {
        _ = try await request(
            method: "DELETE",
            url: try endpoint(base, "/v1/links/\(linkID)"),
            token: token,
            json: nil
        )
    }

    func connect(
        base: URL,
        token: String,
        onEvent: @escaping (AppSocketEvent) -> Void
    ) -> AppLinkConnection {
        let connection = URLSessionAppLinkConnection(session: session)
        connection.onEvent = onEvent
        if let url = AppRelayURL.webSocketURL(base: base, token: token) {
            connection.open(url)
        } else {
            onEvent(.failure(messageID: "", code: "bad_url", message: "中转地址无效"))
            onEvent(.closed)
        }
        return connection
    }

    private func endpoint(_ base: URL, _ path: String) throws -> URL {
        guard let url = AppRelayURL.endpoint(base, path: path) else {
            throw AppLinkError.invalidURL
        }
        return url
    }

    private func request(
        method: String,
        url: URL,
        token: String?,
        json: [String: String]?
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (200..<300).contains(status) else {
            throw AppLinkError.rejected(body["error"] as? String ?? "http_\(status)")
        }
        return body
    }
}

private final class URLSessionAppLinkConnection: NSObject, AppLinkConnection, URLSessionWebSocketDelegate {
    var onEvent: ((AppSocketEvent) -> Void)?
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()

    init(session: URLSession) {
        self.session = session
    }

    func open(_ url: URL) {
        let socket = session.webSocketTask(with: url)
        lock.lock()
        task = socket
        lock.unlock()
        socket.resume()
        receive(socket)
    }

    func send(_ payload: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        lock.lock()
        let socket = task
        lock.unlock()
        socket?.send(.string(text)) { [weak self] error in
            if error != nil {
                self?.onEvent?(.closed)
            }
        }
    }

    func close() {
        lock.lock()
        let socket = task
        task = nil
        lock.unlock()
        socket?.cancel(with: .goingAway, reason: nil)
    }

    private func receive(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.onEvent?(Self.parse(text))
                self.receive(socket)
            case .success:
                self.receive(socket)
            case .failure:
                self.onEvent?(.closed)
            }
        }
    }

    private static func parse(_ text: String) -> AppSocketEvent {
        guard let data = text.data(using: .utf8),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = body["op"] as? String else {
            return .failure(messageID: "", code: "bad_frame", message: "无法识别中转消息")
        }
        let messageID = body["message_id"] as? String ?? ""
        switch op {
        case "ready":
            return .ready
        case "accepted":
            return .accepted(messageID: messageID)
        case "inbound":
            return .inbound(
                linkID: body["link_id"] as? String ?? "",
                messageID: messageID,
                text: body["text"] as? String ?? "",
                androidID: body["android_id"] as? String ?? ""
            )
        case "reply":
            return .reply(
                linkID: body["link_id"] as? String ?? "",
                messageID: messageID,
                text: body["text"] as? String ?? ""
            )
        case "error":
            return .failure(
                messageID: messageID,
                code: body["code"] as? String ?? "error",
                message: body["message"] as? String ?? "中转失败"
            )
        default:
            return .failure(messageID: messageID, code: "bad_op", message: "无法处理")
        }
    }
}
