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

    /// 读取剪贴板文本。
    func read() -> String? {
        pasteboard.string(forType: .string)
    }
}
