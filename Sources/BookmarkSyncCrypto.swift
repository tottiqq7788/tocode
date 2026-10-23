import CryptoKit
import Foundation

enum BookmarkSyncCrypto {
    static let verifierMessage = "tocode-bookmark-room-v1"
    static let maxCiphertextBytes = 4_194_304
    static let opsCompactAfter = 200

    static func roomID(for secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func verifier(for secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(verifierMessage.utf8), using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    static func encryptionKey(from secret: String) -> SymmetricKey {
        let digest = SHA256.hash(data: Data(secret.utf8))
        return SymmetricKey(data: Data(digest))
    }

    static func encrypt(snapshot: BookmarkLedgerSnapshot, secret: String) throws -> String {
        let data = try JSONEncoder().encode(snapshot)
        let sealed = try AES.GCM.seal(data, using: encryptionKey(from: secret))
        guard let combined = sealed.combined else {
            throw BookmarkSyncCryptoError.sealFailed
        }
        guard combined.count <= maxCiphertextBytes else {
            throw BookmarkSyncCryptoError.tooLarge
        }
        return combined.base64EncodedString()
    }

    static func decrypt(ciphertextBase64: String, secret: String) throws -> BookmarkLedgerSnapshot {
        guard let combined = Data(base64Encoded: ciphertextBase64) else {
            throw BookmarkSyncCryptoError.invalidCiphertext
        }
        let box = try AES.GCM.SealedBox(combined: combined)
        let plain = try AES.GCM.open(box, using: encryptionKey(from: secret))
        return try JSONDecoder().decode(BookmarkLedgerSnapshot.self, from: plain)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8)
        let right = Array(b.utf8)
        guard left.count == right.count else { return false }
        var diff: UInt8 = 0
        for index in left.indices {
            diff |= left[index] ^ right[index]
        }
        return diff == 0
    }
}

enum BookmarkSyncCryptoError: Error, LocalizedError {
    case sealFailed
    case tooLarge
    case invalidCiphertext

    var errorDescription: String? {
        switch self {
        case .sealFailed:
            return "书签账本加密失败。"
        case .tooLarge:
            return "加密后的书签账本超过 4MB 上限。"
        case .invalidCiphertext:
            return "无法解析远端书签密文。"
        }
    }
}
