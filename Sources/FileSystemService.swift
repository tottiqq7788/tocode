import Foundation

/// 文件系统访问服务：枚举目录、判断条目类型与路径存在性，以及新增/删除文件。
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

    /// 在目录中创建指定格式的空文件，返回创建后的完整路径。
    /// 文件名已包含扩展名时以输入为准；否则追加所选格式的扩展名。
    func createFile(in directory: String, name rawName: String, format: FileFormat) throws -> String {
        guard let fileName = FileFormat.resolveFileName(rawName, format: format) else {
            throw FileSystemServiceError.emptyFileName
        }
        let path = (directory as NSString).appendingPathComponent(fileName)
        guard !fm.fileExists(atPath: path) else {
            throw FileSystemServiceError.fileAlreadyExists(fileName)
        }
        guard fm.createFile(atPath: path, contents: Data(), attributes: nil) else {
            throw FileSystemServiceError.createFailed(fileName)
        }
        return path
    }

    /// 在目录中创建空文件夹，返回创建后的完整路径。
    func createDirectory(in directory: String, name rawName: String) throws -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FileSystemServiceError.emptyFileName
        }
        let name = (trimmed as NSString).lastPathComponent
        guard !name.isEmpty else {
            throw FileSystemServiceError.emptyFileName
        }
        let path = (directory as NSString).appendingPathComponent(name)
        guard !fm.fileExists(atPath: path) else {
            throw FileSystemServiceError.fileAlreadyExists(name)
        }
        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: false)
        } catch {
            throw FileSystemServiceError.createFailed(name)
        }
        return path
    }

    /// 把路径移入废纸篓（可恢复）。
    func trashItem(at path: String) throws {
        var resultingURL: NSURL?
        do {
            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resultingURL)
        } catch {
            throw FileSystemServiceError.deleteFailed((path as NSString).lastPathComponent)
        }
    }

    /// 清空目录内全部内容（含隐藏项），逐项移入废纸篓。
    func trashContents(of directory: String) throws {
        for entry in entries(in: directory, includeHidden: true) {
            try trashItem(at: entry.path)
        }
    }
}

/// 常见新增文件格式。
enum FileFormat: String, CaseIterable {
    case txt
    case md
    case csv
    case json
    case docx
    case xlsx
    case pptx
    case pdf

    var fileExtension: String { rawValue }

    var displayName: String {
        switch self {
        case .txt: return "纯文本"
        case .md: return "Markdown"
        case .csv: return "CSV 表格"
        case .json: return "JSON"
        case .docx: return "Word 文档"
        case .xlsx: return "Excel 表格"
        case .pptx: return "PPT 演示"
        case .pdf: return "PDF 文档"
        }
    }

    /// 规整文件名：空白返回 nil；去掉目录前缀；无扩展名时追加所选格式扩展名，已有扩展名时以输入为准。
    static func resolveFileName(_ rawName: String, format: FileFormat) -> String? {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = (trimmed as NSString).lastPathComponent
        guard !base.isEmpty else { return nil }
        if (base as NSString).pathExtension.isEmpty {
            return base + "." + format.fileExtension
        }
        return base
    }
}

enum FileSystemServiceError: LocalizedError {
    case emptyFileName
    case fileAlreadyExists(String)
    case createFailed(String)
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyFileName:
            return "文件名不能为空"
        case .fileAlreadyExists(let name):
            return "文件已存在：\(name)"
        case .createFailed(let name):
            return "无法创建文件：\(name)"
        case .deleteFailed(let name):
            return "无法删除：\(name)"
        }
    }
}

extension FileManager {
    func removeItemIfExists(at path: String) throws {
        if fileExists(atPath: path) {
            try removeItem(atPath: path)
        }
    }
}
