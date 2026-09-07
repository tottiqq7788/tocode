import Foundation

struct WeChatQRCode: Codable, Equatable {
    let qrcode: String
    let qrcodeImageContent: String

    enum CodingKeys: String, CodingKey {
        case qrcode
        case qrcodeImageContent = "qrcode_img_content"
    }

    init(qrcode: String, qrcodeImageContent: String = "") {
        self.qrcode = qrcode
        self.qrcodeImageContent = qrcodeImageContent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        qrcode = try container.decodeIfPresent(String.self, forKey: .qrcode) ?? ""
        qrcodeImageContent = try container.decodeIfPresent(
            String.self,
            forKey: .qrcodeImageContent
        ) ?? ""
    }

    var scanURLString: String {
        if qrcodeImageContent.lowercased().hasPrefix("http") {
            return qrcodeImageContent
        }
        var components = URLComponents(string: "https://liteapp.weixin.qq.com/q/7GiQu1")!
        components.queryItems = [
            URLQueryItem(name: "qrcode", value: qrcode),
            URLQueryItem(name: "bot_type", value: "3")
        ]
        return components.url!.absoluteString
    }
}

struct WeChatQRCodeStatus: Codable, Equatable {
    let status: String
    let botToken: String?
    let baseURL: String?

    enum CodingKeys: String, CodingKey {
        case status
        case botToken = "bot_token"
        case baseURL = "baseurl"
    }
}

struct WeChatUpdates: Codable, Equatable {
    let ret: Int
    let messages: [WeChatMessage]
    let cursor: String
    let longPollingTimeoutMilliseconds: Int?

    enum CodingKeys: String, CodingKey {
        case ret
        case messages = "msgs"
        case cursor = "get_updates_buf"
        case longPollingTimeoutMilliseconds = "longpolling_timeout_ms"
    }

    init(
        ret: Int = 0,
        messages: [WeChatMessage] = [],
        cursor: String = "",
        longPollingTimeoutMilliseconds: Int? = nil
    ) {
        self.ret = ret
        self.messages = messages
        self.cursor = cursor
        self.longPollingTimeoutMilliseconds = longPollingTimeoutMilliseconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ret = try container.decodeIfPresent(Int.self, forKey: .ret) ?? 0
        messages = try container.decodeIfPresent([WeChatMessage].self, forKey: .messages) ?? []
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor) ?? ""
        longPollingTimeoutMilliseconds = try container.decodeIfPresent(
            Int.self,
            forKey: .longPollingTimeoutMilliseconds
        )
    }
}

struct WeChatMessage: Codable, Equatable {
    let fromUserID: String
    let toUserID: String
    let contextToken: String
    let groupID: String
    let messageType: Int
    let messageID: String
    let createTime: Int64?
    let items: [WeChatItem]

    enum CodingKeys: String, CodingKey {
        case fromUserID = "from_user_id"
        case toUserID = "to_user_id"
        case contextToken = "context_token"
        case groupID = "group_id"
        case messageType = "message_type"
        case messageID = "msg_id"
        case createTime = "create_time"
        case items = "item_list"
    }

    init(
        fromUserID: String,
        toUserID: String = "",
        contextToken: String = "",
        groupID: String = "",
        messageType: Int = 1,
        messageID: String = "",
        createTime: Int64? = nil,
        items: [WeChatItem]
    ) {
        self.fromUserID = fromUserID
        self.toUserID = toUserID
        self.contextToken = contextToken
        self.groupID = groupID
        self.messageType = messageType
        self.messageID = messageID
        self.createTime = createTime
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fromUserID = try container.decodeIfPresent(String.self, forKey: .fromUserID) ?? ""
        toUserID = try container.decodeIfPresent(String.self, forKey: .toUserID) ?? ""
        contextToken = try container.decodeIfPresent(String.self, forKey: .contextToken) ?? ""
        groupID = try container.decodeIfPresent(String.self, forKey: .groupID) ?? ""
        messageType = try container.decodeIfPresent(Int.self, forKey: .messageType) ?? 0
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID) ?? ""
        createTime = try container.decodeIfPresent(Int64.self, forKey: .createTime)
        items = try container.decodeIfPresent([WeChatItem].self, forKey: .items) ?? []
    }
}

struct WeChatItem: Codable, Equatable {
    let type: Int
    let textItem: WeChatTextItem?
    let imageItem: WeChatImageItem?
    let voiceItem: WeChatVoiceItem?
    let fileItem: WeChatFileItem?
    let videoItem: WeChatVideoItem?
    let reference: WeChatReference?

    enum CodingKeys: String, CodingKey {
        case type
        case textItem = "text_item"
        case imageItem = "image_item"
        case voiceItem = "voice_item"
        case fileItem = "file_item"
        case videoItem = "video_item"
        case reference = "ref_msg"
    }

    init(
        type: Int,
        textItem: WeChatTextItem? = nil,
        imageItem: WeChatImageItem? = nil,
        voiceItem: WeChatVoiceItem? = nil,
        fileItem: WeChatFileItem? = nil,
        videoItem: WeChatVideoItem? = nil,
        reference: WeChatReference? = nil
    ) {
        self.type = type
        self.textItem = textItem
        self.imageItem = imageItem
        self.voiceItem = voiceItem
        self.fileItem = fileItem
        self.videoItem = videoItem
        self.reference = reference
    }
}

struct WeChatQuotedItem: Codable, Equatable {
    let type: Int
    let textItem: WeChatTextItem?
    let imageItem: WeChatImageItem?
    let voiceItem: WeChatVoiceItem?
    let fileItem: WeChatFileItem?
    let videoItem: WeChatVideoItem?

    enum CodingKeys: String, CodingKey {
        case type
        case textItem = "text_item"
        case imageItem = "image_item"
        case voiceItem = "voice_item"
        case fileItem = "file_item"
        case videoItem = "video_item"
    }
}

struct WeChatReference: Codable, Equatable {
    let messageItem: WeChatQuotedItem?

    enum CodingKeys: String, CodingKey {
        case messageItem = "message_item"
    }
}

struct WeChatTextItem: Codable, Equatable {
    let text: String
}

struct WeChatMedia: Codable, Equatable {
    let encryptQueryParameter: String
    let aesKey: String
    let directURL: String

    enum CodingKeys: String, CodingKey {
        case encryptQueryParameter = "encrypt_query_param"
        case aesKey = "aes_key"
        case directURL = "url"
    }

    init(encryptQueryParameter: String = "", aesKey: String = "", directURL: String = "") {
        self.encryptQueryParameter = encryptQueryParameter
        self.aesKey = aesKey
        self.directURL = directURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        encryptQueryParameter = try container.decodeIfPresent(
            String.self,
            forKey: .encryptQueryParameter
        ) ?? ""
        aesKey = try container.decodeIfPresent(String.self, forKey: .aesKey) ?? ""
        directURL = try container.decodeIfPresent(String.self, forKey: .directURL) ?? ""
    }
}

struct WeChatImageItem: Codable, Equatable {
    let url: String
    let aesKey: String
    let media: WeChatMedia?

    enum CodingKeys: String, CodingKey {
        case url
        case aesKey = "aeskey"
        case media
    }

    init(url: String = "", aesKey: String = "", media: WeChatMedia? = nil) {
        self.url = url
        self.aesKey = aesKey
        self.media = media
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        aesKey = try container.decodeIfPresent(String.self, forKey: .aesKey) ?? ""
        media = try container.decodeIfPresent(WeChatMedia.self, forKey: .media)
    }
}

struct WeChatVoiceItem: Codable, Equatable {
    let textItem: WeChatTextItem?
    let text: String
    let media: WeChatMedia?
    let aesKey: String

    enum CodingKeys: String, CodingKey {
        case textItem = "text_item"
        case text
        case media
        case aesKey = "aeskey"
    }

    init(
        textItem: WeChatTextItem? = nil,
        text: String = "",
        media: WeChatMedia? = nil,
        aesKey: String = ""
    ) {
        self.textItem = textItem
        self.text = text
        self.media = media
        self.aesKey = aesKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        textItem = try container.decodeIfPresent(WeChatTextItem.self, forKey: .textItem)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        media = try container.decodeIfPresent(WeChatMedia.self, forKey: .media)
        aesKey = try container.decodeIfPresent(String.self, forKey: .aesKey) ?? ""
    }

    var transcription: String {
        let nested = textItem?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return nested.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : nested
    }
}

struct WeChatFileItem: Codable, Equatable {
    let fileName: String
    let media: WeChatMedia?
    let url: String

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case media
        case url
    }

    init(fileName: String = "", media: WeChatMedia? = nil, url: String = "") {
        self.fileName = fileName
        self.media = media
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        media = try container.decodeIfPresent(WeChatMedia.self, forKey: .media)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
    }
}

struct WeChatVideoItem: Codable, Equatable {
    let fileName: String
    let media: WeChatMedia?
    let url: String

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case media
        case url
    }

    init(fileName: String = "", media: WeChatMedia? = nil, url: String = "") {
        self.fileName = fileName
        self.media = media
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        media = try container.decodeIfPresent(WeChatMedia.self, forKey: .media)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
    }
}

struct WeChatMediaDescriptor: Equatable, Sendable {
    let directURL: String
    let encryptQueryParameter: String
    let aesKey: String

    var isDownloadable: Bool {
        !encryptQueryParameter.isEmpty || directURL.lowercased().hasPrefix("https://")
    }
}

struct WeChatCredential: Codable, Equatable {
    let token: String
    let baseURL: URL
}

enum WeChatTrustPolicy {
    static func isTrustedAPIURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        return host == "weixin.qq.com" || host.hasSuffix(".weixin.qq.com")
    }
}
