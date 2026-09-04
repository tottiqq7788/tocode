import AppKit

/// 快捷键菜单项只使用自定义圆形图标反映实际生效状态。
enum ShortcutMenuAppearance {
    static func symbolName(enabled: Bool) -> String {
        enabled ? "checkmark.circle.fill" : "circle"
    }

    static func apply(to item: NSMenuItem, enabled: Bool) {
        // NSMenuItem.state = .on 会额外绘制系统勾选；始终关闭它，避免与自定义勾选圆重复。
        item.state = .off
        item.image = NSImage(
            systemSymbolName: symbolName(enabled: enabled),
            accessibilityDescription: nil
        )
    }
}
