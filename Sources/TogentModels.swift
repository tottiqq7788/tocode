import Foundation

enum TogentImageInputCapability: String, Codable, Equatable {
    case multimodal
    case textOnly
    case unknown
}

struct TogentModelOption: Codable, Equatable {
    let publishedModelID: String
    let providerName: String
    let imageInput: TogentImageInputCapability

    init(
        publishedModelID: String,
        providerName: String,
        imageInput: TogentImageInputCapability = .unknown
    ) {
        self.publishedModelID = publishedModelID
        self.providerName = providerName
        self.imageInput = imageInput
    }

    private enum CodingKeys: String, CodingKey {
        case publishedModelID
        case providerName
        case imageInput
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        publishedModelID = try values.decode(String.self, forKey: .publishedModelID)
        providerName = try values.decode(String.self, forKey: .providerName)
        imageInput = try values.decodeIfPresent(
            TogentImageInputCapability.self,
            forKey: .imageInput
        ) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(publishedModelID, forKey: .publishedModelID)
        try values.encode(providerName, forKey: .providerName)
        try values.encode(imageInput, forKey: .imageInput)
    }

    var displayName: String {
        "\(providerName) · \(publishedModelID) · \(capabilityTitle)"
    }

    var capabilityTitle: String {
        switch imageInput {
        case .multimodal:
            return "多模态"
        case .textOnly:
            return "纯文本"
        case .unknown:
            return "能力未知"
        }
    }

    var capabilitySymbolName: String {
        switch imageInput {
        case .multimodal:
            return "photo"
        case .textOnly:
            return "text.alignleft"
        case .unknown:
            return "questionmark.circle"
        }
    }
}

struct TogentRelayAccess: Equatable {
    let baseURL: String
    let bearerToken: String
    let models: [TogentModelOption]
}

struct TogentRole: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var workspacePath: String
    var prompt: String
    var publishedModelID: String
    var isActive: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        workspacePath: String,
        prompt: String,
        publishedModelID: String,
        isActive: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.workspacePath = workspacePath
        self.prompt = prompt
        self.publishedModelID = publishedModelID
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct TogentRoleDraft: Equatable {
    var name: String
    var workspacePath: String
    var prompt: String
    var publishedModelID: String
    var isActive: Bool

    init(
        name: String = "",
        workspacePath: String,
        prompt: String = "",
        publishedModelID: String = "",
        isActive: Bool = false
    ) {
        self.name = name
        self.workspacePath = workspacePath
        self.prompt = prompt
        self.publishedModelID = publishedModelID
        self.isActive = isActive
    }

    init(role: TogentRole) {
        name = role.name
        workspacePath = role.workspacePath
        prompt = role.prompt
        publishedModelID = role.publishedModelID
        isActive = role.isActive
    }
}

enum TogentRoleName {
    static let maximumLength = 80

    static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maximumLength else { return false }
        let scalars = Array(value.unicodeScalars)
        guard let first = scalars.first, isASCIILetter(first) else { return false }
        return scalars.dropFirst().allSatisfy {
            isASCIILetter($0)
                || (48...57).contains($0.value)
                || $0 == "_"
                || $0 == "-"
        }
    }

    static func isValidPartial(_ value: String) -> Bool {
        value.isEmpty || isValid(value)
    }

    private static func isASCIILetter(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}

struct TogentRoleCopyOption: Equatable, Identifiable {
    let sourceRoleID: UUID
    let sourceRoleName: String
    let draft: TogentRoleDraft

    var id: UUID { sourceRoleID }
}

struct TogentInboundLease: Equatable {
    let id: UUID
    let roleID: UUID
    let archiveRoot: URL
}

enum TogentJobState: String, Codable {
    case staged
    case queued
    case running
    case completed
    case failed
}

enum TogentChannel: String, Codable, Equatable {
    case wechat
    case app
}

struct TogentJob: Codable, Equatable, Identifiable {
    let id: UUID
    let deduplicationKey: String
    let roleID: UUID?
    let fromUserID: String
    let contextToken: String
    let messageText: String
    let receivedAt: Date
    var state: TogentJobState
    var attemptCount: Int
    var lastError: String?
    let createdAt: Date
    var updatedAt: Date
    var channel: TogentChannel = .wechat
}

struct TogentReply: Equatable {
    static let openingTag = "<tocode_wechat_files>"
    static let closingTag = "</tocode_wechat_files>"
    static let maximumFileCount = 5

    let text: String
    let relativeFilePaths: [String]

    init(text: String, relativeFilePaths: [String] = []) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.relativeFilePaths = relativeFilePaths
    }

    static func parse(_ raw: String) throws -> TogentReply {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let openingCount = value.components(separatedBy: openingTag).count - 1
        let closingCount = value.components(separatedBy: closingTag).count - 1
        if openingCount == 0, closingCount == 0 {
            guard !value.isEmpty else { throw TogentError.emptyReply }
            return TogentReply(text: value)
        }
        guard openingCount == 1,
              closingCount == 1,
              value.hasSuffix(closingTag),
              let openingRange = value.range(of: openingTag),
              let closingRange = value.range(
                of: closingTag,
                range: openingRange.upperBound..<value.endIndex
              ) else {
            throw TogentError.invalidReplyProtocol
        }

        let payloadText = String(value[openingRange.upperBound..<closingRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payloadData = payloadText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payloadData),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == Set(["files"]),
              let paths = dictionary["files"] as? [String],
              !paths.isEmpty,
              paths.count <= maximumFileCount,
              Set(paths).count == paths.count,
              paths.allSatisfy(isValidRelativeFilePath) else {
            throw TogentError.invalidReplyProtocol
        }
        let text = String(value[..<openingRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TogentReply(text: text, relativeFilePaths: paths)
    }

    private static func isValidRelativeFilePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path.count <= 1_024,
              !path.hasPrefix("/"),
              !path.contains("\0") else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

enum TogentError: Error, Equatable, LocalizedError {
    case unavailable(String)
    case invalidRoleName
    case duplicateRoleName
    case invalidWorkspacePath
    case duplicateWorkspacePath
    case overlappingWorkspacePath
    case workspaceOutsideBoundary
    case modelNotConfigured
    case modelUnavailable
    case roleNotFound
    case busy
    case database(String)
    case workspace(String)
    case runtimeMissing
    case runtimeLaunch(String)
    case runtimeExited(String)
    case rpcProtocol(String)
    case rpcTimeout
    case noActiveRole
    case emptyReply
    case invalidReplyProtocol
    case replyFileRejected(String)
    case gitOperationDenied
    case gitFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return "Togent 不可用：\(message)"
        case .invalidRoleName:
            return "角色名称须以英文字母开头，只能包含英文字母、数字、连字符或下划线，且最多 80 个字符。"
        case .duplicateRoleName:
            return "角色名称已存在（不区分大小写）。"
        case .invalidWorkspacePath:
            return "项目路径必须是有效的绝对目录路径。"
        case .duplicateWorkspacePath:
            return "该项目路径已被其他角色使用。"
        case .overlappingWorkspacePath:
            return "角色项目路径不能与其他角色目录互相包含。"
        case .workspaceOutsideBoundary:
            return "路径解析后超出允许的角色项目边界。"
        case .modelNotConfigured:
            return "当前角色尚未配置模型，请在 Tocode 的“微信 → togent”中编辑角色并选择健康模型。"
        case .modelUnavailable:
            return "所选模型当前不可用，请在角色设置中重新选择健康模型。"
        case .roleNotFound:
            return "角色不存在。"
        case .busy:
            return "当前仍有微信消息归档、Togent 任务排队或运行，请等待完成后再修改角色。"
        case .database(let message):
            return "Togent 数据库失败：\(message)"
        case .workspace(let message):
            return "角色项目目录初始化失败：\(message)"
        case .runtimeMissing:
            return "Togent 内置 Pi 运行时缺失，请重新安装或构建 Tocode。"
        case .runtimeLaunch(let message):
            return "Togent 运行时启动失败：\(message)"
        case .runtimeExited(let message):
            return "Togent 运行时意外退出：\(message)"
        case .rpcProtocol(let message):
            return "Togent RPC 协议错误：\(message)"
        case .rpcTimeout:
            return "Togent 任务执行超时。"
        case .noActiveRole:
            return "尚未激活 Togent 角色，请在 Tocode 的“微信 → togent”中配置并勾选角色。"
        case .emptyReply:
            return "Agent 已结束，但没有生成可发送的文本回复。"
        case .invalidReplyProtocol:
            return "Agent 生成的微信文件回复格式无效，未发送任何文件。"
        case .replyFileRejected(let message):
            return "Agent 请求发送的文件被拒绝：\(message)"
        case .gitOperationDenied:
            return "该远程 Git 操作不在 Togent 允许范围内。"
        case .gitFailed(let message):
            return "受控 Git 操作失败：\(message)"
        }
    }
}

enum TogentReplyChunker {
    static func chunks(_ text: String, limit: Int = 1_800) -> [String] {
        guard limit > 0 else { return [] }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        var result: [String] = []
        var start = normalized.startIndex
        while start < normalized.endIndex {
            var end = normalized.index(start, offsetBy: limit, limitedBy: normalized.endIndex)
                ?? normalized.endIndex
            if end < normalized.endIndex,
               let breakIndex = normalized[start..<end].lastIndex(where: { $0 == "\n" || $0 == " " }),
               normalized.distance(from: breakIndex, to: end) < max(40, limit / 3) {
                end = normalized.index(after: breakIndex)
            }
            let chunk = normalized[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                result.append(String(chunk))
            }
            start = end
        }
        return result
    }
}
