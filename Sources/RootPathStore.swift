import Foundation

/// 根文件夹路径的持久化存储。
struct RootPathStore {
    static let key = "tocode.rootFolderPath"
    static let defaultRoot = "/Users/admin/Documents"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> String? {
        defaults.string(forKey: Self.key)
    }

    func save(_ path: String) {
        defaults.set(path, forKey: Self.key)
    }

    /// 重置根文件夹为默认目录。
    func reset() {
        save(Self.defaultRoot)
    }

    /// 解析当前应使用的根文件夹：已保存且存在的路径优先，否则回落到默认目录。
    func resolveRoot(isDirectory: (String) -> Bool) -> String {
        if let saved = load(), isDirectory(saved) {
            return saved
        }
        return Self.defaultRoot
    }
}
