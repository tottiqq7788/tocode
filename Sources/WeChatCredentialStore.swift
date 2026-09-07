import Foundation
import Security

enum WeChatCredentialStoreError: Error, Equatable {
    case encodingFailed
    case keychain(OSStatus)
}

protocol WeChatCredentialStoring {
    func load() -> WeChatCredential?
    func save(_ credential: WeChatCredential) throws
    func delete() throws
}

final class KeychainWeChatCredentialStore: WeChatCredentialStoring {
    private let service: String
    private let account: String

    init(service: String = "com.tocode.app.wechat", account: String = "ilink-bot") {
        self.service = service
        self.account = account
    }

    func load() -> WeChatCredential? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let credential = try? JSONDecoder().decode(WeChatCredential.self, from: data),
              !credential.token.isEmpty,
              WeChatTrustPolicy.isTrustedAPIURL(credential.baseURL) else {
            return nil
        }
        return credential
    }

    func save(_ credential: WeChatCredential) throws {
        guard !credential.token.isEmpty, WeChatTrustPolicy.isTrustedAPIURL(credential.baseURL) else {
            throw WeChatCredentialStoreError.encodingFailed
        }
        let data = try JSONEncoder().encode(credential)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return
        }
        if status != errSecItemNotFound {
            throw WeChatCredentialStoreError.keychain(status)
        }

        var insertion = baseQuery
        insertion[kSecValueData as String] = data
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw WeChatCredentialStoreError.keychain(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WeChatCredentialStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
    }
}
