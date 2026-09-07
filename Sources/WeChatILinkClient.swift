import Foundation

enum WeChatTransportError: Error, Equatable {
    case invalidURL
    case untrustedURL
    case invalidResponse
    case httpStatus(Int)
    case unauthorized
    case serverFailure(Int)
    case apiFailure(Int)
    case emptyQRCode
}

protocol WeChatILinkTransporting: AnyObject {
    func fetchQRCode() async throws -> WeChatQRCode
    func fetchQRCodeStatus(qrcode: String) async throws -> WeChatQRCodeStatus
    func getUpdates(credential: WeChatCredential, cursor: String) async throws -> WeChatUpdates
    func downloadMedia(_ descriptor: WeChatMediaDescriptor) async throws -> Data
}

final class WeChatILinkClient: WeChatILinkTransporting, @unchecked Sendable {
    static let officialBaseURL = URL(string: "https://ilinkai.weixin.qq.com")!
    static let channelVersion = "2.0.1"
    private static let cdnBaseURL = URL(string: "https://novac2c.cdn.weixin.qq.com/c2c")!

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let randomUIN: () -> UInt32

    init(
        session: URLSession? = nil,
        randomUIN: @escaping () -> UInt32 = { UInt32.random(in: 0...UInt32.max) }
    ) {
        self.session = session ?? Self.makeProductionSession()
        self.randomUIN = randomUIN
        decoder = JSONDecoder()
        encoder = JSONEncoder()
    }

    func fetchQRCode() async throws -> WeChatQRCode {
        var components = URLComponents(
            url: Self.officialBaseURL.appendingPathComponent("ilink/bot/get_bot_qrcode"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "bot_type", value: "3")]
        guard let url = components.url else { throw WeChatTransportError.invalidURL }
        let data = try await perform(request(url: url, method: "GET", token: nil), timeout: 15)
        let result = try decoder.decode(WeChatQRCode.self, from: data)
        guard !result.qrcode.isEmpty else {
            throw WeChatTransportError.emptyQRCode
        }
        return result
    }

    func fetchQRCodeStatus(qrcode: String) async throws -> WeChatQRCodeStatus {
        var components = URLComponents(
            url: Self.officialBaseURL.appendingPathComponent("ilink/bot/get_qrcode_status"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "qrcode", value: qrcode)]
        guard let url = components.url else { throw WeChatTransportError.invalidURL }
        let data = try await perform(request(url: url, method: "GET", token: nil), timeout: 60)
        return try decoder.decode(WeChatQRCodeStatus.self, from: data)
    }

    func getUpdates(credential: WeChatCredential, cursor: String) async throws -> WeChatUpdates {
        guard WeChatTrustPolicy.isTrustedAPIURL(credential.baseURL) else {
            throw WeChatTransportError.untrustedURL
        }
        let url = credential.baseURL.appendingPathComponent("ilink/bot/getupdates")
        let body = GetUpdatesBody(
            getUpdatesBuffer: cursor,
            baseInfo: BaseInfo(channelVersion: Self.channelVersion)
        )
        let encoded = try encoder.encode(body)
        let data = try await perform(
            request(url: url, method: "POST", token: credential.token, body: encoded),
            timeout: 45
        )
        let updates = try decoder.decode(WeChatUpdates.self, from: data)
        guard updates.ret == 0 else {
            throw WeChatTransportError.apiFailure(updates.ret)
        }
        return updates
    }

    func downloadMedia(_ descriptor: WeChatMediaDescriptor) async throws -> Data {
        let url: URL
        if !descriptor.encryptQueryParameter.isEmpty {
            var components = URLComponents(
                url: Self.cdnBaseURL.appendingPathComponent("download"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(
                    name: "encrypted_query_param",
                    value: descriptor.encryptQueryParameter
                )
            ]
            guard let resolved = components.url else { throw WeChatTransportError.invalidURL }
            url = resolved
        } else {
            guard let direct = URL(string: descriptor.directURL),
                  direct.scheme?.lowercased() == "https" else {
                throw WeChatTransportError.invalidURL
            }
            url = direct
        }

        let (data, response) = try await session.data(for: URLRequest(url: url))
        try validate(response, requiresTrustedFinalURL: false)
        if descriptor.aesKey.isEmpty {
            return data
        }
        return try WeChatCrypto.decryptAESData(data, key: descriptor.aesKey)
    }

    func makeHeaders(token: String?) -> [String: String] {
        let uin = Data(String(randomUIN()).utf8).base64EncodedString()
        var headers = [
            "Content-Type": "application/json",
            "AuthorizationType": "ilink_bot_token",
            "X-WECHAT-UIN": uin
        ]
        if let token, !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    private func request(url: URL, method: String, token: String?, body: Data? = nil) throws -> URLRequest {
        if token != nil && !WeChatTrustPolicy.isTrustedAPIURL(url) {
            throw WeChatTransportError.untrustedURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.allHTTPHeaderFields = makeHeaders(token: token)
        return request
    }

    private func perform(_ request: URLRequest, timeout: TimeInterval) async throws -> Data {
        var request = request
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        try validate(
            response,
            requiresTrustedFinalURL: request.value(forHTTPHeaderField: "Authorization") != nil
        )
        return data
    }

    private func validate(_ response: URLResponse, requiresTrustedFinalURL: Bool) throws {
        guard let http = response as? HTTPURLResponse else {
            throw WeChatTransportError.invalidResponse
        }
        if requiresTrustedFinalURL {
            guard let finalURL = http.url, WeChatTrustPolicy.isTrustedAPIURL(finalURL) else {
                throw WeChatTransportError.untrustedURL
            }
        } else if http.url?.scheme?.lowercased() != "https" {
            throw WeChatTransportError.untrustedURL
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw WeChatTransportError.unauthorized
        case 500..<600:
            throw WeChatTransportError.serverFailure(http.statusCode)
        default:
            throw WeChatTransportError.httpStatus(http.statusCode)
        }
    }

    private struct GetUpdatesBody: Encodable {
        let getUpdatesBuffer: String
        let baseInfo: BaseInfo

        enum CodingKeys: String, CodingKey {
            case getUpdatesBuffer = "get_updates_buf"
            case baseInfo = "base_info"
        }
    }

    private struct BaseInfo: Encodable {
        let channelVersion: String

        enum CodingKeys: String, CodingKey {
            case channelVersion = "channel_version"
        }
    }

    private static func makeProductionSession() -> URLSession {
        URLSession(
            configuration: .ephemeral,
            delegate: WeChatRedirectDelegate(),
            delegateQueue: nil
        )
    }
}

private final class WeChatRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url, target.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        if let original = task.originalRequest?.url,
           WeChatTrustPolicy.isTrustedAPIURL(original),
           !WeChatTrustPolicy.isTrustedAPIURL(target) {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
