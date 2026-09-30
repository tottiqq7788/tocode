import CommonCrypto
import CryptoKit
import Foundation
import Security

final class ModelRelayLocalKeyVault {
    private let iterations: UInt32

    init(iterations: UInt32 = 210_000) {
        self.iterations = iterations
    }

    func create(name: String, viewingPassword: String) throws -> (
        record: ModelRelayLocalKeyRecord,
        secret: String
    ) {
        let normalizedName = try ModelRelayValidation.normalizedName(name)
        guard viewingPassword.count >= 8 else {
            throw ModelRelayError.invalidViewingPassword
        }
        let secret = "tc_" + Self.base64URL(try Self.randomBytes(count: 32))
        let salt = try Self.randomBytes(count: 16)
        let key = try deriveKey(password: viewingPassword, salt: salt)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(Data(secret.utf8), using: key)
        } catch {
            throw ModelRelayError.cryptoFailed
        }
        guard let combined = sealed.combined else {
            throw ModelRelayError.cryptoFailed
        }
        return (
            ModelRelayLocalKeyRecord(
                name: normalizedName,
                digest: Self.digest(secret),
                salt: salt,
                sealedSecret: combined
            ),
            secret
        )
    }

    func reveal(_ record: ModelRelayLocalKeyRecord, viewingPassword: String) throws -> String {
        guard viewingPassword.count >= 8 else {
            throw ModelRelayError.wrongViewingPassword
        }
        do {
            let key = try deriveKey(password: viewingPassword, salt: record.salt)
            let sealed = try AES.GCM.SealedBox(combined: record.sealedSecret)
            let clear = try AES.GCM.open(sealed, using: key)
            guard let secret = String(data: clear, encoding: .utf8),
                  Self.constantTimeEqual(Self.digest(secret), record.digest) else {
                throw ModelRelayError.wrongViewingPassword
            }
            return secret
        } catch let error as ModelRelayError {
            throw error
        } catch {
            throw ModelRelayError.wrongViewingPassword
        }
    }

    func authenticates(_ presentedSecret: String, records: [ModelRelayLocalKeyRecord]) -> Bool {
        let candidate = Self.digest(presentedSecret)
        var matched: UInt8 = 0
        for record in records {
            matched |= Self.constantTimeEqual(candidate, record.digest) ? 1 : 0
        }
        return matched == 1
    }

    static func digest(_ secret: String) -> Data {
        Data(SHA256.hash(data: Data(secret.utf8)))
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    private func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        var output = [UInt8](repeating: 0, count: 32)
        let status: Int32 = salt.withUnsafeBytes { saltBytes in
            password.withCString { passwordBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes,
                    password.lengthOfBytes(using: .utf8),
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    &output,
                    output.count
                )
            }
        }
        guard status == kCCSuccess else {
            throw ModelRelayError.cryptoFailed
        }
        return SymmetricKey(data: output)
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw ModelRelayError.cryptoFailed
        }
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
