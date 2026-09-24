import Foundation

/// 左键目录树「恢复上次展开位置」的纯规则与持久化。
struct DirectoryMenuResumeStore {
    static let key = "tocode.directoryMenu.resumePath"
    let defaults: UserDefaults

    init(defaults: UserDefaults = TocodePreferences.shared) {
        self.defaults = defaults
    }

    func load() -> String? {
        defaults.string(forKey: Self.key)
    }

    func save(_ path: String) {
        defaults.set(DirectoryMenuResume.standardize(path), forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

enum DirectoryMenuResume {
    static func standardize(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    static func isUnderRoot(path: String, root: String) -> Bool {
        let p = standardize(path)
        let r = standardize(root)
        return p == r || p.hasPrefix(r + "/")
    }

    /// 解析下次应展示的目录：记忆路径仍在根下且存在则用之，否则沿父级回退，最后落到根。
    static func resolveDisplayDirectory(
        saved: String?,
        root: String,
        isDirectory: (String) -> Bool
    ) -> String {
        let rootStd = standardize(root)
        guard let saved else { return rootStd }
        var path = standardize(saved)
        while true {
            if isUnderRoot(path: path, root: rootStd), isDirectory(path) {
                return path
            }
            if path == rootStd || path == "/" || path.isEmpty {
                return rootStd
            }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path { return rootStd }
            path = parent
        }
    }

    static func parentDirectory(of path: String) -> String {
        (standardize(path) as NSString).deletingLastPathComponent
    }

    /// 相对根的面包屑，根自身返回「根目录」。
    static func breadcrumb(from root: String, to path: String) -> String {
        let rootStd = standardize(root)
        let pathStd = standardize(path)
        if pathStd == rootStd { return "根目录" }
        guard isUnderRoot(path: pathStd, root: rootStd) else {
            return (pathStd as NSString).lastPathComponent
        }
        let prefix = rootStd.hasSuffix("/") ? rootStd : rootStd + "/"
        let relative = String(pathStd.dropFirst(prefix.count))
        return relative.isEmpty ? "根目录" : relative
    }
}
