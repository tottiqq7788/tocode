import Foundation
import Security

protocol BookmarkSyncKeyStoring: AnyObject {
    func loadPlaintext() throws -> String?
    func savePlaintext(_ secret: String) throws
    func deletePlaintext() throws
}

final class KeychainBookmarkSyncKeyStore: BookmarkSyncKeyStoring {
    static let service = "com.tocode.app.bookmark-sync.remote-key"
    static let account = "remote-key"
    static let minimumLength = 32

    private let service: String
    private let account: String

    init(
        service: String = KeychainBookmarkSyncKeyStore.service,
        account: String = KeychainBookmarkSyncKeyStore.account
    ) {
        self.service = service
        self.account = account
    }

    func loadPlaintext() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // 禁止弹出钥匙串解锁框：否则会卡住 @MainActor，IPC/扩展桥全部无响应。
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            throw BookmarkSyncKeyError.keychain(status)
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw BookmarkSyncKeyError.keychain(status)
        }
        return value
    }

    func savePlaintext(_ secret: String) throws {
        let normalized = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= Self.minimumLength, normalized == secret else {
            throw BookmarkSyncKeyError.invalidSecret
        }
        let data = Data(secret.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return
        }
        guard status == errSecItemNotFound else {
            throw BookmarkSyncKeyError.keychain(status)
        }
        var insertion = baseQuery()
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw BookmarkSyncKeyError.keychain(addStatus)
        }
    }

    func deletePlaintext() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BookmarkSyncKeyError.keychain(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum BookmarkSyncKeyError: Error, LocalizedError {
    case invalidSecret
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidSecret:
            return "远程同步密钥至少 32 个字符，且首尾不能有空白。"
        case .keychain(let status):
            return "钥匙串不可用（\(status)）。"
        }
    }
}

enum BookmarkSyncKeyFactory {
    /// 32 字节随机数，base64url 无填充。
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess)
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
