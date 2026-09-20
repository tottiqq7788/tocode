import Foundation
import Security

enum WeChatTransportError: Error, Equatable {
    case invalidURL
    case untrustedURL
    case invalidResponse
    case httpStatus(Int)
    case unauthorized
    case serverFailure(Int)
    case apiFailure(Int)
    case emptyQRCode
    case emptyUploadParam
    case missingEncryptedParam
}

enum WeChatOutboundMediaKind: Equatable {
    case image
    case file

    var mediaType: Int {
        switch self {
        case .image: return 1
        case .file: return 3
        }
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]

    static func classify(path: String) -> WeChatOutboundMediaKind {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return imageExtensions.contains(ext) ? .image : .file
    }
}

struct WeChatUploadedMedia: Equatable {
    var encryptQueryParameter: String
    var aesKey: String
    var byteCount: Int
}

enum WeChatOutboundMessageItem: Equatable {
    case text(String)
    case image(WeChatUploadedMedia)
    case file(name: String, media: WeChatUploadedMedia)
}

protocol WeChatILinkTransporting: AnyObject {
    func fetchQRCode() async throws -> WeChatQRCode
    func fetchQRCodeStatus(qrcode: String) async throws -> WeChatQRCodeStatus
    func getUpdates(credential: WeChatCredential, cursor: String) async throws -> WeChatUpdates
    func downloadMedia(_ descriptor: WeChatMediaDescriptor) async throws -> Data
    func sendText(credential: WeChatCredential, toUserID: String, contextToken: String, text: String) async throws
    func sendItems(
        credential: WeChatCredential,
        toUserID: String,
        contextToken: String,
        items: [WeChatOutboundMessageItem]
    ) async throws
    func uploadMedia(
        credential: WeChatCredential,
        toUserID: String,
        fileName: String,
        data: Data,
        kind: WeChatOutboundMediaKind
    ) async throws -> WeChatUploadedMedia
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

    func sendText(
        credential: WeChatCredential,
        toUserID: String,
        contextToken: String,
        text: String
    ) async throws {
        try await sendItems(
            credential: credential,
            toUserID: toUserID,
            contextToken: contextToken,
            items: [.text(text)]
        )
    }

    func sendItems(
        credential: WeChatCredential,
        toUserID: String,
        contextToken: String,
        items: [WeChatOutboundMessageItem]
    ) async throws {
        let url = credential.baseURL.appendingPathComponent("ilink/bot/sendmessage")
        let message = OutboundMessage(
            fromUserID: "",
            toUserID: toUserID,
            clientID: UUID().uuidString,
            messageType: 2,
            messageState: 2,
            contextToken: contextToken,
            items: items.map(WeChatOutboundItem.init)
        )
        let body = OutboundEnvelope(msg: message, baseInfo: BaseInfo(channelVersion: Self.channelVersion))
        let encoded = try encoder.encode(body)
        let data = try await perform(
            request(url: url, method: "POST", token: credential.token, body: encoded),
            timeout: 20
        )
        // 微信实际成功响应可能不返回 ret 字段（或返回空体/额外字段）。
        // 缺失 ret 视为成功，仅显式非零 ret 才视为业务失败，避免“已送达却误报失败”。
        if let outbound = try? decoder.decode(OutboundResponse.self, from: data) {
            guard outbound.ret == 0 else {
                throw WeChatTransportError.apiFailure(outbound.ret)
            }
        }
    }

    func uploadMedia(
        credential: WeChatCredential,
        toUserID: String,
        fileName: String,
        data: Data,
        kind: WeChatOutboundMediaKind
    ) async throws -> WeChatUploadedMedia {
        _ = fileName
        let keyData = randomBytes(16)
        let aesHex = keyData.map { String(format: "%02x", $0) }.joined()
        let filekey = randomBytes(16).map { String(format: "%02x", $0) }.joined()
        let ciphertext = try WeChatCrypto.encryptAESData(data, key: aesHex)
        let uploadURL = credential.baseURL.appendingPathComponent("ilink/bot/getuploadurl")
        let requestBody = UploadURLBody(
            filekey: filekey,
            mediaType: kind.mediaType,
            toUserID: toUserID,
            rawsize: data.count,
            rawfilemd5: WeChatCrypto.md5Hex(data),
            filesize: ciphertext.count,
            noNeedThumb: true,
            aeskey: aesHex,
            baseInfo: BaseInfo(channelVersion: Self.channelVersion)
        )
        let encoded = try encoder.encode(requestBody)
        let responseData = try await perform(
            request(url: uploadURL, method: "POST", token: credential.token, body: encoded),
            timeout: 20
        )
        let parsed = try decoder.decode(UploadURLResponse.self, from: responseData)
        if let ret = parsed.ret, ret != 0 {
            throw WeChatTransportError.apiFailure(ret)
        }
        guard let uploadParam = parsed.uploadParam, !uploadParam.isEmpty else {
            throw WeChatTransportError.emptyUploadParam
        }

        var components = URLComponents(
            url: Self.cdnBaseURL.appendingPathComponent("upload"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "encrypted_query_param", value: uploadParam),
            URLQueryItem(name: "filekey", value: filekey)
        ]
        guard let cdnURL = components.url else { throw WeChatTransportError.invalidURL }
        var cdnRequest = URLRequest(url: cdnURL)
        cdnRequest.httpMethod = "POST"
        cdnRequest.httpBody = ciphertext
        cdnRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let result = try await performResult(cdnRequest, timeout: 45, requiresTrustedFinalURL: false)
        let encryptedParam = headerValue("x-encrypted-param", in: result.headers)
        guard let encryptedParam, !encryptedParam.isEmpty else {
            throw WeChatTransportError.missingEncryptedParam
        }
        return WeChatUploadedMedia(
            encryptQueryParameter: encryptedParam,
            aesKey: Data(aesHex.utf8).base64EncodedString(),
            byteCount: data.count
        )
    }

    private func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            guard let pointer = buffer.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, count, pointer)
        }
        return data
    }

    private func headerValue(_ name: String, in headers: [AnyHashable: Any]) -> String? {
        for (key, value) in headers {
            guard String(describing: key).lowercased() == name.lowercased() else { continue }
            if let text = value as? String { return text }
            return String(describing: value)
        }
        return nil
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
        try await performResult(
            request,
            timeout: timeout,
            requiresTrustedFinalURL: request.value(forHTTPHeaderField: "Authorization") != nil
        ).data
    }

    private struct HTTPResult {
        let data: Data
        let headers: [AnyHashable: Any]
    }

    private func performResult(
        _ request: URLRequest,
        timeout: TimeInterval,
        requiresTrustedFinalURL: Bool
    ) async throws -> HTTPResult {
        var request = request
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        try validate(response, requiresTrustedFinalURL: requiresTrustedFinalURL)
        let headers = (response as? HTTPURLResponse)?.allHeaderFields ?? [:]
        return HTTPResult(data: data, headers: headers)
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

    private struct OutboundEnvelope: Encodable {
        let msg: OutboundMessage
        let baseInfo: BaseInfo

        enum CodingKeys: String, CodingKey {
            case msg
            case baseInfo = "base_info"
        }
    }

    private struct OutboundMessage: Encodable {
        let fromUserID: String
        let toUserID: String
        let clientID: String
        let messageType: Int
        let messageState: Int
        let contextToken: String
        let items: [WeChatOutboundItem]

        enum CodingKeys: String, CodingKey {
            case fromUserID = "from_user_id"
            case toUserID = "to_user_id"
            case clientID = "client_id"
            case messageType = "message_type"
            case messageState = "message_state"
            case contextToken = "context_token"
            case items = "item_list"
        }
    }

    private struct WeChatOutboundItem: Encodable {
        let type: Int
        let textItem: WeChatTextItem?
        let imageItem: WeChatOutboundImageItem?
        let fileItem: WeChatOutboundFileItem?

        enum CodingKeys: String, CodingKey {
            case type
            case textItem = "text_item"
            case imageItem = "image_item"
            case fileItem = "file_item"
        }

        init(_ item: WeChatOutboundMessageItem) {
            switch item {
            case .text(let text):
                type = 1
                textItem = WeChatTextItem(text: text)
                imageItem = nil
                fileItem = nil
            case .image(let media):
                type = 2
                textItem = nil
                imageItem = WeChatOutboundImageItem(media: WeChatOutboundMedia(media))
                fileItem = nil
            case .file(let name, let media):
                type = 4
                textItem = nil
                imageItem = nil
                fileItem = WeChatOutboundFileItem(
                    media: WeChatOutboundMedia(media),
                    fileName: name,
                    len: String(media.byteCount)
                )
            }
        }
    }

    private struct WeChatOutboundMedia: Encodable {
        let encryptQueryParameter: String
        let aesKey: String
        let encryptType: Int

        enum CodingKeys: String, CodingKey {
            case encryptQueryParameter = "encrypt_query_param"
            case aesKey = "aes_key"
            case encryptType = "encrypt_type"
        }

        init(_ media: WeChatUploadedMedia) {
            encryptQueryParameter = media.encryptQueryParameter
            aesKey = media.aesKey
            encryptType = 1
        }
    }

    private struct WeChatOutboundImageItem: Encodable {
        let media: WeChatOutboundMedia
    }

    private struct WeChatOutboundFileItem: Encodable {
        let media: WeChatOutboundMedia
        let fileName: String
        let len: String

        enum CodingKeys: String, CodingKey {
            case media
            case fileName = "file_name"
            case len
        }
    }

    private struct UploadURLBody: Encodable {
        let filekey: String
        let mediaType: Int
        let toUserID: String
        let rawsize: Int
        let rawfilemd5: String
        let filesize: Int
        let noNeedThumb: Bool
        let aeskey: String
        let baseInfo: BaseInfo

        enum CodingKeys: String, CodingKey {
            case filekey
            case mediaType = "media_type"
            case toUserID = "to_user_id"
            case rawsize
            case rawfilemd5
            case filesize
            case noNeedThumb = "no_need_thumb"
            case aeskey
            case baseInfo = "base_info"
        }
    }

    private struct UploadURLResponse: Decodable {
        let ret: Int?
        let uploadParam: String?

        enum CodingKeys: String, CodingKey {
            case ret
            case uploadParam = "upload_param"
        }
    }

    private struct OutboundResponse: Decodable {
        let ret: Int

        enum CodingKeys: String, CodingKey {
            case ret
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let ret = try container.decodeIfPresent(Int.self, forKey: .ret) {
                self.ret = ret
            } else if let raw = try container.decodeIfPresent(String.self, forKey: .ret), let parsed = Int(raw) {
                self.ret = parsed
            } else {
                // 缺失 ret 字段按成功处理；由调用方决定是否解析成功。
                self.ret = 0
            }
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
