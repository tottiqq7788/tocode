import AppKit

@MainActor
enum AnkerCredentialPrompt {
    static let menuTitle = ExtendedSettingsStore.akCredentialTitle

    static func prompt() -> String? {
        let alert = NSAlert()
        alert.messageText = menuTitle
        alert.informativeText = "输入新的安克 API 密钥，保存后替换 pi、Codex（通过 CC Switch）、Hermes 和 OpenCode 的密钥。\n\nHermes 将使用安克 DeepSeek V4 Pro。已打开的会话可能需要重新加载。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = AnkerSecureTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        field.placeholderString = "输入新的 AK 密钥"
        field.setAccessibilityLabel("新的 AK 密钥")
        alert.accessoryView = field
        defer { field.stringValue = "" }
        while alert.runModalFocusingFirstTextField() == .alertFirstButtonReturn {
            if let key = try? AnkerCredentialService.normalizedKey(field.stringValue) { return key }
            alert.informativeText = AnkerCredentialError.invalidKey.localizedDescription
            alert.window.makeFirstResponder(field)
        }
        return nil
    }

    static func showResult(_ result: Result<Void, Error>) {
        let alert = NSAlert()
        switch result {
        case .success:
            alert.messageText = "AK密钥已更新"
            alert.informativeText = "已保存到 pi、Codex（通过 CC Switch）、Hermes 和 OpenCode。\n\npi 和 Codex 的后续请求会读取新密钥。已打开的 Hermes、OpenCode 会话请重新加载或重开；若 pi 使用过手动登录凭据，可打开 /model 重新加载配置。"
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = "AK密钥未保存成功"
            alert.informativeText = (error as? AnkerCredentialError)?.localizedDescription
                ?? AnkerCredentialError.writeFailed.localizedDescription
        }
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// The accessory application has no Edit menu, so provide the two input shortcuts locally.
@MainActor
private final class AnkerSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v":
            guard let editor = currentEditor() else { return super.performKeyEquivalent(with: event) }
            editor.paste(self)
            return true
        case "a":
            selectText(self)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}
