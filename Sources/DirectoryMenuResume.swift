import Foundation

/// 左键目录树「历史」：记住上次点击的文件/文件夹，供根菜单「历史」子菜单展示其同级目录。
struct DirectoryMenuResumeStore {
    static let key = "tocode.directoryMenu.lastClickedPath"
    /// 旧版整菜单恢复用的键，读取时忽略并清理。
    static let legacyResumeKey = "tocode.directoryMenu.resumePath"
    let defaults: UserDefaults

    init(defaults: UserDefaults = TocodePreferences.shared) {
        self.defaults = defaults
    }

    func load() -> String? {
        if defaults.object(forKey: Self.legacyResumeKey) != nil {
            defaults.removeObject(forKey: Self.legacyResumeKey)
        }
        return defaults.string(forKey: Self.key)
    }

    func save(_ path: String) {
        defaults.set(DirectoryMenuResume.standardize(path), forKey: Self.key)
        defaults.removeObject(forKey: Self.legacyResumeKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.legacyResumeKey)
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

    static func parentDirectory(of path: String) -> String {
        (standardize(path) as NSString).deletingLastPathComponent
    }

    /// 上次点击项的同级目录（其父文件夹）。无效时返回 nil。
    static func siblingDirectory(
        lastClicked: String?,
        root: String,
        isDirectory: (String) -> Bool
    ) -> String? {
        guard let lastClicked else { return nil }
        let rootStd = standardize(root)
        let clicked = standardize(lastClicked)
        guard isUnderRoot(path: clicked, root: rootStd) else { return nil }
        let parent = parentDirectory(of: clicked)
        guard isUnderRoot(path: parent, root: rootStd), isDirectory(parent) else { return nil }
        return parent
    }
}
