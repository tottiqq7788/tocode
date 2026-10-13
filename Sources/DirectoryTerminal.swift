import Foundation

enum DirectoryTerminalError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let path):
            return "无法在「\(path)」打开终端。"
        }
    }
}

enum DirectoryTerminalCommand {
    /// 目录只作为 osascript 参数传入，由 AppleScript `quoted form of` 引用。
    static let script = """
    on run argv
      tell application "Terminal"
        activate
        do script "cd " & quoted form of (item 1 of argv)
      end tell
    end run
    """

    static func arguments(directory: String) -> [String] {
        ["-e", script, "--", directory]
    }

    static func standardizedDirectory(_ directory: String) throws -> String {
        let path = (directory as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DirectoryTerminalError.unavailable(directory)
        }
        return path
    }
}

protocol DirectoryTerminalLaunching {
    func openTerminal(at directory: String) throws
}

struct SystemDirectoryTerminalLauncher: DirectoryTerminalLaunching {
    func openTerminal(at directory: String) throws {
        let path = try DirectoryTerminalCommand.standardizedDirectory(directory)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = DirectoryTerminalCommand.arguments(directory: path)
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DirectoryTerminalError.unavailable(directory)
        }
    }
}
