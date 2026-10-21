import Foundation

/// 只列出本机已经存在的 Hermes 档案。不新建、不删除。
enum HermesProfileCatalog {
    static let idPattern = #"^[a-z0-9][a-z0-9_-]{0,63}$"#
    static let markers = ["config.yaml", ".env", "SOUL.md", "profile.yaml", "auth.json", "state.db"]

    static func names(home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> [String] {
        names(
            home: home,
            isDirectory: { path in
                var isDir: ObjCBool = false
                return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            },
            fileExists: { fileManager.fileExists(atPath: $0) },
            childNames: { path in
                (try? fileManager.contentsOfDirectory(atPath: path)) ?? []
            }
        )
    }

    static func names(
        home: String,
        isDirectory: (String) -> Bool,
        fileExists: (String) -> Bool,
        childNames: (String) -> [String]
    ) -> [String] {
        let root = (home as NSString).appendingPathComponent(".hermes")
        var result: [String] = []
        if isDirectory(root) { result.append("default") }
        let profiles = (root as NSString).appendingPathComponent("profiles")
        guard isDirectory(profiles) else { return result }
        let deleted = (profiles as NSString).appendingPathComponent(".deleted")
        let named = childNames(profiles).filter { name in
            guard isSafe(name), name != "default", isDirectory((profiles as NSString).appendingPathComponent(name)) else {
                return false
            }
            if fileExists((deleted as NSString).appendingPathComponent(name)) { return false }
            return markers.contains { marker in
                fileExists((profiles as NSString).appendingPathComponent("\(name)/\(marker)"))
            }
        }.sorted()
        result.append(contentsOf: named)
        return result
    }

    static func isSafe(_ name: String) -> Bool {
        name == "default" || name.range(of: idPattern, options: .regularExpression) != nil
    }

    /// 不在清单里、或名字不能安全放进路径时，回到 default。
    static func accepted(_ raw: String, among names: [String]) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "default" : trimmed
        let pool = names.isEmpty ? ["default"] : names
        guard pool.contains(candidate), isSafe(candidate) else { return "default" }
        return candidate
    }

    /// default 保持现有无前缀接口。非法名字返回空，避免被拼进 URL。
    static func prefix(for name: String) -> String {
        guard name != "default", isSafe(name), !name.contains("/"), !name.contains("..") else { return "" }
        return "/p/\(name)"
    }

    static func home(userHome: String, profile: String) -> String {
        let root = (userHome as NSString).appendingPathComponent(".hermes")
        guard profile != "default", isSafe(profile) else { return root }
        return (root as NSString).appendingPathComponent("profiles/\(profile)")
    }

    static func envURL(userHome: String, profile: String) -> URL {
        URL(fileURLWithPath: (home(userHome: userHome, profile: profile) as NSString).appendingPathComponent(".env"))
    }
}
