import Foundation

/// 文件持久化的微信凭据存储：避免 ad-hoc 签名导致每次启动都触发钥匙串授权。
/// 凭据是本地个人 Bot Token，存入 Application Support 下、权限 0600，仅当前用户可读。
final class FileWeChatCredentialStore: WeChatCredentialStoring {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.fileURL = base
                .appendingPathComponent("com.tocode.app", isDirectory: true)
                .appendingPathComponent("wechat-credential.json")
        }
    }

    func load() -> WeChatCredential? {
        guard let data = try? Data(contentsOf: fileURL),
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
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(credential)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path
        )
    }

    func delete() throws {
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }
}
