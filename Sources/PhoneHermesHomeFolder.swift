import Foundation

/// 手机新建项目时从用户主目录往下选文件夹。手机只发相对主目录的路径，一切以 Mac 解析结果为准。
enum PhoneHermesHomeFolder {
    static let maxPathLength = 1024
    static let maxFolders = 500

    /// 解析成主目录内一个现存文件夹的真实路径；越界、含 . 或 ..、指向文件时返回 nil。
    static func resolve(_ relative: String, home: String, fileManager: FileManager = .default) -> String? {
        guard relative.count <= maxPathLength,
              !relative.hasPrefix("/"),
              relative.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let segments = relative.isEmpty ? [] : parts
        guard segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let root = canonical(home)
        let joined = segments.reduce(root) { ($0 as NSString).appendingPathComponent($1) }
        let real = canonical(joined)
        guard real == root || real.hasPrefix(root + "/") else { return nil }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue else { return nil }
        return real
    }

    /// 列出某层下面的子文件夹名，不列文件；解析后跑出主目录的链接不列。
    static func folders(
        under relative: String,
        home: String,
        includeHidden: Bool,
        fileSystem: FileSystemService = FileSystemService()
    ) -> PhoneHermesAppReply {
        guard let directory = resolve(relative, home: home) else {
            return .failure("这个文件夹不在主目录里或已不存在")
        }
        let root = canonical(home)
        var names: [String] = []
        var truncated = false
        for entry in fileSystem.entries(in: directory, includeHidden: includeHidden) where entry.kind == .directory {
            let real = canonical(entry.path)
            guard real.hasPrefix(root + "/") else { continue }
            if names.count >= maxFolders {
                truncated = true
                break
            }
            names.append(entry.name)
        }
        let shown = directory == root ? "" : String(directory.dropFirst(root.count + 1))
        return .success(truncated ? "只显示了前 \(maxFolders) 个文件夹" : "", body: ["path": shown, "folders": names])
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
