import Foundation
import Security

protocol ModelRelayUpstreamKeyStoring: AnyObject {
    func load(id: UUID) throws -> String?
    func save(_ secret: String, id: UUID) throws
    func delete(id: UUID) throws
}

final class KeychainModelRelayUpstreamKeyStore: ModelRelayUpstreamKeyStoring {
    static let service = "com.tocode.app.model-relay.upstream"

    private let service: String

    init(service: String = KeychainModelRelayUpstreamKeyStore.service) {
        self.service = service
    }

    func load(id: UUID) throws -> String? {
        var query = baseQuery(id: id)
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
            throw ModelRelayError.keychain(status)
        }
        return value
    }

    func save(_ secret: String, id: UUID) throws {
        let normalized = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized == secret else {
            throw ModelRelayError.keyNotFound
        }
        let data = Data(secret.utf8)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(id: id) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return
        }
        guard status == errSecItemNotFound else {
            throw ModelRelayError.keychain(status)
        }
        var insertion = baseQuery(id: id)
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ModelRelayError.keychain(addStatus)
        }
    }

    func delete(id: UUID) throws {
        let status = SecItemDelete(baseQuery(id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ModelRelayError.keychain(status)
        }
    }

    private func baseQuery(id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString
        ]
    }
}
