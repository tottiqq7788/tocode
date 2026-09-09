import Foundation
import AppKit

enum FinderSelectionError: Error, Equatable {
    case notExactlyOne
    case notPermitted
    case scriptFailed
    case invalidPath
}

protocol AppleScriptRunning {
    func execute(_ source: String) -> Result<String, FinderSelectionError>
}

/// 访达当前恰好单选一个有效项目时，解析可设为根目录的路径。不要求访达位于前台。
struct FinderSelectionService {
    let script: AppleScriptRunning
    let fs: FileSystemService

    init(
        script: AppleScriptRunning = NSAppleScriptRunner(),
        fs: FileSystemService = FileSystemService()
    ) {
        self.script = script
        self.fs = fs
    }

    /// 成功则返回应写入的根目录；否则返回错误且不暗示调用方改写持久化。
    func resolveInitializationDirectory() -> Result<String, FinderSelectionError> {
        switch script.execute(Self.selectionScript) {
        case .failure(let error):
            return .failure(error)
        case .success(let raw):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .failure(.notExactlyOne) }
            return resolveRoot(fromSelectedLocation: text)
        }
    }

    func resolveRoot(fromSelectedLocation rawLocation: String) -> Result<String, FinderSelectionError> {
        let rawPath: String
        if rawLocation.hasPrefix("file:") {
            guard let url = URL(string: rawLocation), url.isFileURL else {
                return .failure(.invalidPath)
            }
            rawPath = url.path
        } else {
            // 保留纯路径输入，便于隔离文件系统逻辑的单元测试。
            rawPath = rawLocation
        }
        let path = (rawPath as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return .failure(.invalidPath)
        }
        if isDir.boolValue {
            return .success(path)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard fs.isExistingDirectory(parent) else {
            return .failure(.invalidPath)
        }
        return .success((parent as NSString).standardizingPath)
    }

    /// 解析访达当前恰好单选的文件或文件夹本身路径（不做目录归约）。
    func resolveSelectedItemPath() -> Result<String, FinderSelectionError> {
        switch script.execute(Self.selectionScript) {
        case .failure(let error):
            return .failure(error)
        case .success(let raw):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .failure(.notExactlyOne) }
            let rawPath: String
            if text.hasPrefix("file:") {
                guard let url = URL(string: text), url.isFileURL else {
                    return .failure(.invalidPath)
                }
                rawPath = url.path
            } else {
                rawPath = text
            }
            let path = (rawPath as NSString).standardizingPath
            guard FileManager.default.fileExists(atPath: path) else {
                return .failure(.invalidPath)
            }
            return .success(path)
        }
    }

    static let selectionScript = """
        tell application "Finder"
            set selectedItems to selection
            if (count of selectedItems) is not 1 then return ""
            set selectedItem to item 1 of selectedItems
            return URL of selectedItem
        end tell
        """
}

struct NSAppleScriptRunner: AppleScriptRunning {
    func execute(_ source: String) -> Result<String, FinderSelectionError> {
        guard let appleScript = NSAppleScript(source: source) else {
            return .failure(.scriptFailed)
        }
        var error: NSDictionary?
        let descriptor = appleScript.executeAndReturnError(&error)
        if let error {
            let number = error["NSAppleScriptErrorNumber"] as? Int
            if number == -1743 {
                return .failure(.notPermitted)
            }
            return .failure(.scriptFailed)
        }
        return .success(descriptor.stringValue ?? "")
    }
}
