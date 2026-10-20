import Foundation

/// 这台 Mac 给手机对话用的工作目录。不进入可分享配置。
struct PhoneHermesPathStore {
    static let key = "tocode.phoneHermesPath"

    let defaults: UserDefaults
    let isDirectory: (String) -> Bool

    init(
        defaults: UserDefaults = TocodePreferences.shared,
        isDirectory: @escaping (String) -> Bool = { path in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    ) {
        self.defaults = defaults
        self.isDirectory = isDirectory
    }

    var savedPath: String {
        defaults.string(forKey: Self.key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func configuredDirectory() -> String? {
        let path = savedPath
        guard !path.isEmpty, isDirectory(path) else { return nil }
        return path
    }

    func save(_ path: String) {
        defaults.set(path, forKey: Self.key)
    }
}
