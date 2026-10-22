import AppKit

@MainActor
enum BindingKeyPrompt {
    enum ManagedAction {
        case set(String)
        case clear
        case cancel
    }

    static func setSecret() -> String? {
        let secret = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        secret.placeholderString = "至少 8 个字符"
        let confirmation = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        confirmation.placeholderString = "再次输入绑定密钥"
        let stack = NSStackView(views: [
            labeled("绑定密钥", secret),
            labeled("确认密钥", confirmation)
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 70)

        let alert = NSAlert()
        alert.messageText = "设置绑定密钥"
        alert.informativeText = "手机扫码后需输入此密钥才能完成绑定。密钥明文只保存在本机钥匙串。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.accessoryView = stack
        defer {
            secret.stringValue = ""
            confirmation.stringValue = ""
        }
        while alert.runModalFocusingFirstTextField() == .alertFirstButtonReturn {
            let value = secret.stringValue
            if value.count < 8 || value != value.trimmingCharacters(in: .whitespacesAndNewlines) {
                alert.informativeText = BindingKeyError.invalidSecret.localizedDescription
                continue
            }
            if value != confirmation.stringValue {
                alert.informativeText = BindingKeyError.mismatch.localizedDescription
                continue
            }
            return value
        }
        return nil
    }

    static func manage(hasSecret: Bool, revealed: String?) -> ManagedAction {
        let alert = NSAlert()
        alert.messageText = "绑定密钥"
        if let revealed {
            alert.informativeText = "当前密钥：\n\(revealed)\n\n可复制到剪贴板，或重置 / 清除。"
            alert.addButton(withTitle: "复制")
            alert.addButton(withTitle: "重置…")
            alert.addButton(withTitle: "清除…")
            alert.addButton(withTitle: "关闭")
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(revealed, forType: .string)
                return .cancel
            case .alertSecondButtonReturn:
                if let next = setSecret() { return .set(next) }
                return .cancel
            case .alertThirdButtonReturn:
                let confirm = NSAlert()
                confirm.alertStyle = .warning
                confirm.messageText = "清除绑定密钥？"
                confirm.informativeText = "清除后须重新设置才能绑定新的安卓设备；已有关联不受影响。"
                confirm.addButton(withTitle: "清除")
                confirm.addButton(withTitle: "取消")
                return confirm.runModal() == .alertFirstButtonReturn ? .clear : .cancel
            default:
                return .cancel
            }
        }
        if hasSecret {
            alert.informativeText = "设备验证后可查看或管理绑定密钥。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return .cancel
        }
        return setSecret().map { .set($0) } ?? .cancel
    }

    private static func labeled(_ title: String, _ field: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let row = NSStackView(views: [label, field])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        return row
    }
}
