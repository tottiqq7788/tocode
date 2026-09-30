import Foundation

struct ModelRelayConfiguration: Codable, Equatable {
    static let currentVersion = 1
    static let defaultPort: UInt16 = 27_800

    var version: Int
    var port: UInt16
    var providers: [ModelRelayProvider]
    var localKeys: [ModelRelayLocalKeyRecord]
    var pendingUpstreamKeyDeletions: [UUID]

    init(
        version: Int = Self.currentVersion,
        port: UInt16 = Self.defaultPort,
        providers: [ModelRelayProvider] = [],
        localKeys: [ModelRelayLocalKeyRecord] = [],
        pendingUpstreamKeyDeletions: [UUID] = []
    ) {
        self.version = version
        self.port = port
        self.providers = providers
        self.localKeys = localKeys
        self.pendingUpstreamKeyDeletions = pendingUpstreamKeyDeletions
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case port
        case providers
        case localKeys
        case pendingUpstreamKeyDeletions
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        port = try values.decode(UInt16.self, forKey: .port)
        providers = try values.decode([ModelRelayProvider].self, forKey: .providers)
        localKeys = try values.decode([ModelRelayLocalKeyRecord].self, forKey: .localKeys)
        pendingUpstreamKeyDeletions = try values.decodeIfPresent(
            [UUID].self,
            forKey: .pendingUpstreamKeyDeletions
        ) ?? []
    }
}

struct ModelRelayProvider: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var baseURL: String
    var keys: [ModelRelayUpstreamKeyReference]
    var models: [ModelRelayModelRoute]

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        keys: [ModelRelayUpstreamKeyReference] = [],
        models: [ModelRelayModelRoute] = []
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.keys = keys
        self.models = models
    }

    var upstreamKey: ModelRelayUpstreamKeyReference? {
        keys.first
    }
}

struct ModelRelayUpstreamKeyReference: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

struct ModelRelayModelRoute: Codable, Equatable, Identifiable {
    let id: UUID
    let upstreamModelID: String
    var alias: String

    init(id: UUID = UUID(), upstreamModelID: String, alias: String) {
        self.id = id
        self.upstreamModelID = upstreamModelID
        self.alias = alias
    }
}

struct ModelRelayLocalKeyRecord: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let digest: Data
    let salt: Data
    let sealedSecret: Data
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        digest: Data,
        salt: Data,
        sealedSecret: Data,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.digest = digest
        self.salt = salt
        self.sealedSecret = sealedSecret
        self.createdAt = createdAt
    }
}

struct ModelRelayConnectionInfo: Equatable {
    let baseURL: String
    let apiKey: String
    let models: [String]

    var clipboardText: String {
        let modelLines = models.isEmpty
            ? ["- （暂无可用模型）"]
            : models.sorted().map { "- \($0)" }
        return ([
            "Base URL: \(baseURL)",
            "API Key: \(apiKey)",
            "Models:"
        ] + modelLines).joined(separator: "\n")
    }
}

struct ModelRelayProviderConnectionTest {
    let providerID: UUID?
    let baseURL: String
    let secret: String
    let replacesKey: Bool
    let modelIDs: [String]
}

enum ModelRelayRunState: Equatable {
    case stopped
    case starting
    case running(port: UInt16)
    case failed(String)

    var menuText: String {
        switch self {
        case .stopped:
            return "状态：已停止"
        case .starting:
            return "状态：正在启动…"
        case .running(let port):
            return "状态：运行中 · 127.0.0.1:\(port)"
        case .failed(let message):
            return "状态：失败 · \(message)"
        }
    }
}

enum ModelRelayError: Error, Equatable, LocalizedError {
    case invalidName
    case duplicateProviderName
    case duplicateKeyName
    case duplicateAlias
    case providerAlreadyHasKey
    case providerConnectionNotTested
    case persistenceRollback(String)
    case invalidPort
    case invalidBaseURL
    case insecureRemoteBaseURL
    case invalidViewingPassword
    case wrongViewingPassword
    case providerNotFound
    case keyNotFound
    case modelNotFound
    case noHealthyUpstream
    case noModels
    case configurationVersion
    case configurationCorrupt
    case keychain(OSStatus)
    case cryptoFailed
    case upstreamHTTP(Int)
    case upstream(String)
    case listener(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "名称不能为空，也不能只包含空白。"
        case .duplicateProviderName:
            return "厂商名称已存在。"
        case .duplicateKeyName:
            return "Key 名称已存在。"
        case .duplicateAlias:
            return "模型别名已存在。"
        case .providerAlreadyHasKey:
            return "每个厂家只能配置一个上游 Key。"
        case .providerConnectionNotTested:
            return "请先使用当前地址和 Key 测试连接。"
        case .persistenceRollback(let message):
            return "持久化回滚失败：\(message)"
        case .invalidPort:
            return "端口必须是 1024…65535。"
        case .invalidBaseURL:
            return "Base URL 无效，必须包含协议、主机和可选的 /v1 路径。"
        case .insecureRemoteBaseURL:
            return "远程上游必须使用 HTTPS；HTTP 只允许 127.0.0.1、localhost 或 ::1。"
        case .invalidViewingPassword:
            return "查看密码至少需要 8 个字符。"
        case .wrongViewingPassword:
            return "查看密码不正确。"
        case .providerNotFound:
            return "厂商不存在。"
        case .keyNotFound:
            return "Key 不存在。"
        case .modelNotFound:
            return "模型别名不存在。"
        case .noHealthyUpstream:
            return "没有可用的上游 Key。"
        case .noModels:
            return "上游没有返回可用模型。"
        case .configurationVersion:
            return "中转站配置版本不受支持。"
        case .configurationCorrupt:
            return "中转站配置损坏，未自动覆盖。"
        case .keychain(let status):
            return "钥匙串操作失败（\(status)）。"
        case .cryptoFailed:
            return "本地 Key 加密或解密失败。"
        case .upstreamHTTP(let status):
            return "上游请求失败：HTTP \(status)"
        case .upstream(let message):
            return "上游请求失败：\(message)"
        case .listener(let message):
            return "本地监听失败：\(message)"
        }
    }
}

enum ModelRelayValidation {
    static func normalizedName(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80 else {
            throw ModelRelayError.invalidName
        }
        return value
    }

    static func normalizedBaseURL(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              scheme == "https" || scheme == "http" else {
            throw ModelRelayError.invalidBaseURL
        }
        let loopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
        guard scheme == "https" || loopback else {
            throw ModelRelayError.insecureRemoteBaseURL
        }
        var path = components.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path.isEmpty || path == "/" {
            path = "/v1"
        }
        components.path = path
        guard let normalized = components.url?.absoluteString else {
            throw ModelRelayError.invalidBaseURL
        }
        return normalized
    }

    static func endpoint(baseURL: String, route: String) throws -> URL {
        guard let base = URL(string: baseURL) else {
            throw ModelRelayError.invalidBaseURL
        }
        let relative = route.hasPrefix("/") ? String(route.dropFirst()) : route
        return base.appendingPathComponent(relative)
    }
}
