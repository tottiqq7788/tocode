import CommonCrypto
import Foundation

enum WeChatCryptoError: Error, Equatable {
    case invalidKey
    case invalidCiphertext
    case decryptionFailed(Int32)
}

enum WeChatCrypto {
    static func decryptAESData(_ encrypted: Data, key encodedKey: String) throws -> Data {
        guard !encrypted.isEmpty, encrypted.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw WeChatCryptoError.invalidCiphertext
        }
        let key = try parseAESKey(encodedKey)
        let outputCapacity = encrypted.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var outputLength = 0

        let status = output.withUnsafeMutableBytes { outputBuffer in
            encrypted.withUnsafeBytes { encryptedBuffer in
                key.withUnsafeBytes { keyBuffer in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBuffer.baseAddress,
                        key.count,
                        nil,
                        encryptedBuffer.baseAddress,
                        encrypted.count,
                        outputBuffer.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw WeChatCryptoError.decryptionFailed(status)
        }
        output.removeSubrange(outputLength..<output.count)
        return output
    }

    static func parseAESKey(_ encodedKey: String) throws -> Data {
        let raw = encodedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hex = decodeHex(raw), [16, 24, 32].contains(hex.count) {
            return hex
        }

        let padded = raw + String(repeating: "=", count: (4 - raw.count % 4) % 4)
        if let decoded = Data(base64Encoded: padded) {
            if let decodedText = String(data: decoded, encoding: .ascii),
               let hex = decodeHex(decodedText),
               [16, 24, 32].contains(hex.count) {
                return hex
            }
            if [16, 24, 32].contains(decoded.count) {
                return decoded
            }
        }

        if let utf8 = raw.data(using: .utf8), [16, 24, 32].contains(utf8.count) {
            return utf8
        }
        throw WeChatCryptoError.invalidKey
    }

    private static func decodeHex(_ value: String) -> Data? {
        guard !value.isEmpty, value.count.isMultiple(of: 2),
              value.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        var data = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        return data
    }
}
