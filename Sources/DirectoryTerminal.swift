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

struct DirectoryTerminalWindowBinding: Equatable {
    let windowID: Int
    let tty: String
    let path: String
}

struct DirectoryTerminalFrontWindow: Equatable {
    let windowID: Int
    let ttys: [String]
}

enum DirectoryTerminalCommand {
    /// 目录只作为 osascript 参数传入，由 AppleScript `quoted form of` 引用。
    static let script = """
    on run argv
      tell application "Terminal"
        activate
        set openedTab to do script "cd " & quoted form of (item 1 of argv)
        set t to missing value
        repeat 20 times
          try
            set t to tty of openedTab
          end try
          if t is not missing value then exit repeat
          delay 0.05
        end repeat
        if t is missing value then error "tty unavailable"
        set wid to id of front window
        return (wid as text) & linefeed & t
      end tell
    end run
    """

    /// 只读最前窗口的编号和标签 tty，不激活终端，也不接收目录参数。
    static let frontWindowScript = """
    if application "Terminal" is not running then return ""
    tell application "Terminal"
      if (count of windows) is 0 then return ""
      set w to front window
      set wid to id of w
      set ttys to tty of every tab of w
      set AppleScript's text item delimiters to linefeed
      return (wid as text) & linefeed & (ttys as text)
    end tell
    """

    static func arguments(directory: String) -> [String] {
        ["-e", script, "--", directory]
    }

    static func frontWindowArguments() -> [String] {
        ["-e", frontWindowScript]
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

    static func parseOpenedWindow(_ output: String, path: String) -> DirectoryTerminalWindowBinding? {
        let lines = outputLines(output)
        guard lines.count >= 2, let windowID = Int(lines[0]), isTTY(lines[1]) else { return nil }
        return DirectoryTerminalWindowBinding(windowID: windowID, tty: lines[1], path: path)
    }

    static func parseFrontWindow(_ output: String) -> DirectoryTerminalFrontWindow? {
        let lines = outputLines(output)
        guard let first = lines.first, let windowID = Int(first) else { return nil }
        let ttys = lines.dropFirst().filter(isTTY)
        guard !ttys.isEmpty else { return nil }
        return DirectoryTerminalFrontWindow(windowID: windowID, ttys: ttys)
    }

    static func run(arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func outputLines(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func isTTY(_ line: String) -> Bool {
        line.contains("tty") && line != "missing value"
    }
}

enum DirectoryTerminalFollow {
    static func validatedPath(_ path: String?, isDirectory: (String) -> Bool) -> String? {
        guard let path, isDirectory(path) else { return nil }
        return path
    }
}

/// 本次运行内的窗口编号 → 启动目录。原标签不在该窗口时删除记录，避免编号复用。
final class DirectoryTerminalWindowStore {
    private var sessions: [Int: (tty: String, path: String)] = [:]

    func remember(_ binding: DirectoryTerminalWindowBinding) {
        sessions[binding.windowID] = (binding.tty, binding.path)
    }

    func path(matching front: DirectoryTerminalFrontWindow) -> String? {
        guard let session = sessions[front.windowID] else { return nil }
        guard front.ttys.contains(session.tty) else {
            sessions.removeValue(forKey: front.windowID)
            return nil
        }
        return session.path
    }
}

protocol DirectoryTerminalLaunching {
    func openTerminal(at directory: String) throws -> DirectoryTerminalWindowBinding
}

protocol DirectoryTerminalFrontWindowReading {
    func frontWindow() -> DirectoryTerminalFrontWindow?
}

struct SystemDirectoryTerminalLauncher: DirectoryTerminalLaunching {
    func openTerminal(at directory: String) throws -> DirectoryTerminalWindowBinding {
        let path = try DirectoryTerminalCommand.standardizedDirectory(directory)
        guard let output = DirectoryTerminalCommand.run(arguments: DirectoryTerminalCommand.arguments(directory: path)),
              let binding = DirectoryTerminalCommand.parseOpenedWindow(output, path: path) else {
            throw DirectoryTerminalError.unavailable(directory)
        }
        return binding
    }
}

struct SystemDirectoryTerminalFrontWindowReader: DirectoryTerminalFrontWindowReading {
    func frontWindow() -> DirectoryTerminalFrontWindow? {
        guard let output = DirectoryTerminalCommand.run(arguments: DirectoryTerminalCommand.frontWindowArguments()) else {
            return nil
        }
        return DirectoryTerminalCommand.parseFrontWindow(output)
    }
}
