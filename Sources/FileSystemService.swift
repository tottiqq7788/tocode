import Foundation

/// 文件系统访问服务：枚举目录、判断条目类型与路径存在性。
struct FileSystemService {
    let fm: FileManager

    init(fm: FileManager = .default) {
        self.fm = fm
    }

    enum Kind {
        case file
        case directory
    }

    struct Entry {
        let name: String
        let path: String
        let kind: Kind
        let isHidden: Bool
    }

    /// 枚举目录下的条目。默认不过滤隐藏项，但会打上 isHidden 标记。
    /// isHidden：点号前缀或 Finder hidden 属性。
    /// 排序：文件夹在前，其余按名称做本地化比较升序。
    func entries(in directory: String, includeHidden: Bool = true) -> [Entry] {
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else {
            return []
        }
        var result: [Entry] = []
        result.reserveCapacity(names.count)
        for name in names {
            let full = (directory as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            let hidden = isHiddenEntry(name: name, path: full)
            if !includeHidden && hidden { continue }
            result.append(Entry(
                name: name,
                path: full,
                kind: isDir.boolValue ? .directory : .file,
                isHidden: hidden
            ))
        }
        result.sort { a, b in
            if a.kind != b.kind { return a.kind == .directory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return result
    }

    /// 点号前缀，或 URL 资源 isHiddenKey。
    func isHiddenEntry(name: String, path: String) -> Bool {
        if name.hasPrefix(".") { return true }
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.isHiddenKey])
        return values?.isHidden == true
    }

    /// 判断路径是否指向一个真实存在的文件夹。
    func isExistingDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
