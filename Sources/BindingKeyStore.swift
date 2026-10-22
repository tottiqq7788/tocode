import CryptoKit
import Foundation
import Security

protocol BindingKeyStoring: AnyObject {
    func loadPlaintext() throws -> String?
    func savePlaintext(_ secret: String) throws
    func deletePlaintext() throws
}

enum BindingKeyDigest {
    static func hex(of secret: String) -> String {
        Data(SHA256.hash(data: Data(secret.utf8))).map { String(format: "%02x", $0) }.joined()
    }
}

final class KeychainBindingKeyStore: BindingKeyStoring {
    static let service = "com.tocode.app.remote-control.binding-key"
    static let account = "binding-key"

    private let service: String
    private let account: String

    init(
        service: String = KeychainBindingKeyStore.service,
        account: String = KeychainBindingKeyStore.account
    ) {
        self.service = service
        self.account = account
    }

    func loadPlaintext() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            throw BindingKeyError.keychain(status)
        }
        return value
    }

    func savePlaintext(_ secret: String) throws {
        let normalized = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 8, normalized == secret else {
            throw BindingKeyError.invalidSecret
        }
        let data = Data(secret.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return
        }
        guard status == errSecItemNotFound else {
            throw BindingKeyError.keychain(status)
        }
        var insertion = baseQuery()
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw BindingKeyError.keychain(addStatus)
        }
    }

    func deletePlaintext() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BindingKeyError.keychain(status)
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

enum BindingKeyError: Error, LocalizedError {
    case invalidSecret
    case mismatch
    case notSet
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidSecret:
            return "绑定密钥至少 8 个字符，且首尾不能有空白。"
        case .mismatch:
            return "两次输入的绑定密钥不一致。"
        case .notSet:
            return "请先设置绑定密钥。"
        case .keychain(let status):
            return "钥匙串不可用（\(status)）。"
        }
    }
}
