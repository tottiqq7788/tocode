import AppKit

enum KeyboardShortcutMappingPromptResult {
    case save(KeyboardShortcutMappingDraft)
    case delete
    case cancel
}

@MainActor
enum KeyboardShortcutMappingPrompt {
    static func prompt(
        draft: KeyboardShortcutMappingDraft,
        isEditing: Bool
    ) -> KeyboardShortcutMappingPromptResult {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = isEditing ? "编辑键盘映射" : "新增键盘映射"
        alert.informativeText = "点击快捷键框后输入键盘组合。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if isEditing {
            let deleteButton = alert.addButton(withTitle: "删除")
            deleteButton.contentTintColor = .systemRed
        }

        let nameLabel = NSTextField(labelWithString: "名称")
        let nameField = NSTextField(string: draft.name)
        nameField.placeholderString = "例如：打开搜索"

        let sourceLabel = NSTextField(labelWithString: "源快捷键")
        let sourceRecorder = ShortcutRecorderView(shortcut: draft.source)
        sourceRecorder.toolTip = "点击后输入需要被替换的快捷键"

        let targetLabel = NSTextField(labelWithString: "目标快捷键")
        let targetRecorder = ShortcutRecorderView(shortcut: draft.target)
        targetRecorder.toolTip = "点击后输入替换后的快捷键"

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        for view in [
            nameLabel,
            nameField,
            sourceLabel,
            sourceRecorder,
            targetLabel,
            targetRecorder
        ] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
        }
        NSLayoutConstraint.activate([
            nameField.widthAnchor.constraint(equalToConstant: 320),
            sourceRecorder.widthAnchor.constraint(equalToConstant: 320),
            sourceRecorder.heightAnchor.constraint(equalToConstant: 48),
            targetRecorder.widthAnchor.constraint(equalToConstant: 320),
            targetRecorder.heightAnchor.constraint(equalToConstant: 48)
        ])
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 220)
        alert.accessoryView = stack

        let saveButton = alert.buttons[0]
        func updateSaveButton() {
            saveButton.isEnabled =
                !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && sourceRecorder.shortcut != nil
                && targetRecorder.shortcut != nil
        }

        let observer = KeyboardMappingNameObserver(onChange: updateSaveButton)
        nameField.delegate = observer
        sourceRecorder.onChange = { _ in updateSaveButton() }
        targetRecorder.onChange = { _ in updateSaveButton() }
        updateSaveButton()
        alert.window.initialFirstResponder = nameField

        let response = withExtendedLifetime(observer) {
            alert.runModal()
        }
        nameField.delegate = nil
        sourceRecorder.onChange = nil
        targetRecorder.onChange = nil
        switch response {
        case .alertFirstButtonReturn:
            return .save(
                KeyboardShortcutMappingDraft(
                    id: draft.id,
                    name: nameField.stringValue,
                    source: sourceRecorder.shortcut,
                    target: targetRecorder.shortcut
                )
            )
        case .alertThirdButtonReturn where isEditing:
            return .delete
        default:
            return .cancel
        }
    }
}

@MainActor
private final class KeyboardMappingNameObserver: NSObject, NSTextFieldDelegate {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange()
    }
}
