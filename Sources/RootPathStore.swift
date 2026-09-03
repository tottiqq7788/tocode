import Foundation

/// 根文件夹路径的持久化存储。
struct RootPathStore {
    static let key = "tomaid.rootFolderPath"
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
}
