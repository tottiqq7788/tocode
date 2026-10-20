import Foundation

/// 根文件夹路径的持久化存储。
struct RootPathStore {
    static let key = "tocode.rootFolderPath"

    let defaults: UserDefaults
    let homeDirectory: URL

    init(
        defaults: UserDefaults = TocodePreferences.shared,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.defaults = defaults
        self.homeDirectory = homeDirectory
    }

    /// 当前用户文稿目录。不保证该目录存在，也不创建它。
    static func documentsDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        standardized(home.appendingPathComponent("Documents", isDirectory: true).path)
    }

    var documentsDirectory: String {
        Self.documentsDirectory(home: homeDirectory)
    }

    func load() -> String? {
        defaults.string(forKey: Self.key)
    }

    func save(_ path: String) {
        defaults.set(path, forKey: Self.key)
    }

    /// 现存默认目录：文稿目录存在时用文稿，否则用用户主目录。
    func adoptedDefault(isDirectory: (String) -> Bool) -> String {
        let documents = documentsDirectory
        if isDirectory(documents) {
            return documents
        }
        return Self.standardized(homeDirectory.path)
    }

    /// 重置根文件夹为现存默认目录，并返回写入的路径。
    @discardableResult
    func reset(isDirectory: (String) -> Bool) -> String {
        let path = adoptedDefault(isDirectory: isDirectory)
        save(path)
        return path
    }

    /// 已保存且现存的路径原样返回。未保存或已失效时，用现存默认目录覆盖偏好后返回。
    func resolveRoot(isDirectory: (String) -> Bool) -> String {
        if let saved = load(), isDirectory(saved) {
            return saved
        }
        return reset(isDirectory: isDirectory)
    }

    private static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
