import Foundation

enum TogentMenuLayout {
    static let root = "togent"
    static let channels = "频道"
    static let weChatAssociation = "微信关联"
    static let appAssociations = "应用关联"
    static let addAssociation = "新增…"
    static let roles = "角色"
    static let editAssociation = "编辑"
    static let deleteAssociation = "删除"
}

struct AppAssociation: Codable, Equatable, Identifiable {
    var id: String
    var roleID: UUID
    var roleName: String
    var displayName: String
    var androidID: String
    var androidName: String
    var macName: String
}

struct AppRelayConfig: Codable, Equatable {
    var baseURL: String = ""
    var deviceID: String = ""
    var deviceToken: String = ""
    var deviceName: String = ""
}

struct AppLinkFile: Codable, Equatable {
    var links: [AppAssociation] = []
    var pendingUnlinks: [String] = []
}

enum AppRelayURL {
    static func normalized(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        let local = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        return url
    }

    static func endpoint(_ base: URL, path: String) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        parts.path = path
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    static func webSocketURL(base: URL, token: String) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        parts.scheme = base.scheme?.lowercased() == "https" ? "wss" : "ws"
        parts.path = "/v1/ws"
        parts.queryItems = [URLQueryItem(name: "token", value: token)]
        return parts.url
    }
}

enum AppLinkPairingPayload {
    static func make(relay: URL, code: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+#")
        let encoded = relay.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed)
            ?? relay.absoluteString
        return "tocode-app://pair?relay=\(encoded)&code=\(code)"
    }

    static func parse(_ raw: String) -> (relay: URL, code: String)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: text),
              components.scheme == "tocode-app",
              components.host == "pair" else {
            return nil
        }
        let relayRaw = components.queryItems?.first { $0.name == "relay" }?.value ?? ""
        let code = components.queryItems?.first { $0.name == "code" }?.value ?? ""
        guard let relay = AppRelayURL.normalized(relayRaw),
              code.count == 8,
              code.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return (relay, code)
    }
}

enum AppSocketEvent: Equatable {
    case ready
    case inbound(linkID: String, messageID: String, text: String, androidID: String)
    case reply(linkID: String, messageID: String, text: String)
    case accepted(messageID: String)
    case failure(messageID: String, code: String, message: String)
    case closed
}

enum AppLinkError: LocalizedError {
    case invalidURL
    case rejected(String)
    case offline
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "中转地址需要是 https，或本机 http"
        case .rejected(let code):
            return "中转拒绝了这次请求（\(code)）"
        case .offline:
            return "中转连接不可用"
        case .timeout:
            return "等待中转确认超时"
        }
    }
}
