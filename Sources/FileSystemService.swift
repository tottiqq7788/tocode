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

    /// 枚举目录下的条目。隐藏文件也返回（不过滤），但会打上 isHidden 标记。
    /// 排序：文件夹在前，其余按名称做本地化比较升序。
    func entries(in directory: String) -> [Entry] {
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else {
            return []
        }
        var result: [Entry] = []
        result.reserveCapacity(names.count)
        for name in names {
            let full = (directory as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            result.append(Entry(
                name: name,
                path: full,
                kind: isDir.boolValue ? .directory : .file,
                isHidden: name.hasPrefix(".")
            ))
        }
        result.sort { a, b in
            if a.kind != b.kind { return a.kind == .directory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return result
    }

    /// 判断路径是否指向一个真实存在的文件夹。
    func isExistingDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
