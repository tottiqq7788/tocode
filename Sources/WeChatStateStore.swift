import CommonCrypto
import Foundation

struct WeChatReceiveState: Codable, Equatable {
    var cursor: String
    var recentKeys: [String]

    static let empty = WeChatReceiveState(cursor: "", recentKeys: [])
}

protocol WeChatReceiveStateStoring {
    func load() -> WeChatReceiveState
    func save(_ state: WeChatReceiveState) throws
    func reset() throws
}

final class FileWeChatReceiveStateStore: WeChatReceiveStateStoring {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = base
                .appendingPathComponent("com.tocode.app", isDirectory: true)
                .appendingPathComponent("wechat-receive-state.json")
        }
    }

    func load() -> WeChatReceiveState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(WeChatReceiveState.self, from: data) else {
            return .empty
        }
        return WeChatReceiveState(
            cursor: state.cursor,
            recentKeys: Array(state.recentKeys.suffix(WeChatDeduplication.maximumKeys))
        )
    }

    func save(_ state: WeChatReceiveState) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let normalized = WeChatReceiveState(
            cursor: state.cursor,
            recentKeys: Array(state.recentKeys.suffix(WeChatDeduplication.maximumKeys))
        )
        let data = try JSONEncoder().encode(normalized)
        try data.write(to: fileURL, options: .atomic)
    }

    func reset() throws {
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }
}

enum WeChatDeduplication {
    static let maximumKeys = 2000

    static func key(for message: WeChatMessage) -> String {
        if !message.contextToken.isEmpty {
            return "ctx:\(sha256(message.contextToken))"
        }
        if !message.messageID.isEmpty {
            return "msg:\(sha256(message.messageID))"
        }
        let normalized = message.items.map(normalizedItem).joined(separator: "|")
        let fallback = [
            message.fromUserID,
            String(message.createTime ?? 0),
            normalized
        ].joined(separator: "\u{1f}")
        return "content:\(sha256(fallback))"
    }

    private static func normalizedItem(_ item: WeChatItem) -> String {
        switch item.type {
        case 1:
            return "1:\(item.textItem?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")"
        case 2:
            return "2:\(item.imageItem?.media?.encryptQueryParameter ?? item.imageItem?.url ?? "")"
        case 3:
            return "3:\(item.voiceItem?.transcription ?? "")"
        case 4:
            return "4:\(item.fileItem?.fileName ?? ""):\(item.fileItem?.media?.encryptQueryParameter ?? "")"
        case 5:
            return "5:\(item.videoItem?.media?.encryptQueryParameter ?? item.videoItem?.url ?? "")"
        default:
            return "\(item.type)"
        }
    }

    private static func sha256(_ value: String) -> String {
        let data = Data(value.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
