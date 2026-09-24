import AppKit

/// 剪贴板服务：读写文本路径。
struct ClipboardService {
    let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// 复制文本到剪贴板。
    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 复制路径到剪贴板，格式为「路径」（全角括号包裹）。
    func copyPath(_ path: String) {
        copy(Self.formatPath(path))
    }

    /// 按顺序复制多条路径，每行一条「路径」。
    func copyPaths(_ paths: [String]) {
        copy(Self.formatPaths(paths))
    }

    /// 读取剪贴板文本。
    func read() -> String? {
        pasteboard.string(forType: .string)
    }

    static func formatPath(_ path: String) -> String {
        "\u{300C}\(path)\u{300D}"
    }

    static func formatPaths(_ paths: [String]) -> String {
        paths.map(formatPath).joined(separator: "\n")
    }
}

/// 左键目录树普通模式下的 Shift 多选复制会话：累积路径并决定是否吞掉点击以保持菜单打开。
enum DirectoryMenuMultiCopy {
    /// 在普通模式且按住 Shift、点击的是条目（非底部按钮）时，追加路径并返回应保持菜单打开。
    /// 不满足条件时不改动 `sessionPaths`（单次复制由菜单 action 自行重置）。
    static func handleClick(
        mode: DirectoryMenuMode,
        shiftHeld: Bool,
        entryPath: String?,
        sessionPaths: inout [String]
    ) -> Bool {
        guard mode == .normal, shiftHeld, let entryPath else {
            return false
        }
        sessionPaths.append(entryPath)
        return true
    }
}
