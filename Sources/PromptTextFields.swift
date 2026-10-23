import AppKit

/// 弹窗用大气输入框：与键盘映射「名称」同款系统圆角控件，菜单栏应用内支持 ⌘V / ⌘A。
@MainActor
enum PromptTextFields {
    static let defaultWidth: CGFloat = 360

    static func plain(
        string: String = "",
        placeholder: String = "",
        width: CGFloat = defaultWidth
    ) -> NSTextField {
        let field = NSTextField(string: string)
        field.placeholderString = placeholder
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.isEditable = true
        field.isSelectable = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    static func secure(
        string: String = "",
        placeholder: String = "",
        width: CGFloat = defaultWidth
    ) -> NSSecureTextField {
        let field = PromptSecureTextField(string: string)
        field.placeholderString = placeholder
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.isEditable = true
        field.isSelectable = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    static func labeled(_ title: String, _ field: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let row = NSStackView(views: [label, field])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        return row
    }

    static func accessoryStack(_ rows: [NSView], width: CGFloat = defaultWidth) -> NSStackView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        // NSAlert accessoryView 仍用 frame；单行约标签+圆角输入框，双行更高。
        let height = CGFloat(rows.count) * 58 + CGFloat(max(rows.count - 1, 0)) * 10
        stack.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return stack
    }
}

@MainActor
final class PromptSecureTextField: NSSecureTextField {
    convenience init(string: String) {
        self.init(frame: .zero)
        self.stringValue = string
    }

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
