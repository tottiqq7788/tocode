import AppKit

enum ModelAutomationPromptResult {
    case save(ModelAutomationDraft)
    case delete
    case cancel
}

@MainActor
enum ModelAutomationPrompt {
    static func prompt(
        draft: ModelAutomationDraft,
        isEditing: Bool,
        modelAliases: [String]
    ) -> ModelAutomationPromptResult {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = isEditing ? "编辑自动化" : "新增自动化"
        alert.informativeText = "提示词会作为系统提示。触发时，当前选中的文字作为用户输入。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if isEditing {
            let deleteButton = alert.addButton(withTitle: "删除")
            deleteButton.contentTintColor = .systemRed
        }

        let nameLabel = NSTextField(labelWithString: "名称")
        let nameField = NSTextField(string: draft.name)
        nameField.placeholderString = "例如：中译英"

        let promptLabel = NSTextField(labelWithString: "提示词")
        let promptView = NSTextView()
        promptView.isRichText = false
        promptView.font = .systemFont(ofSize: NSFont.systemFontSize)
        promptView.string = draft.prompt
        promptView.isAutomaticQuoteSubstitutionEnabled = false
        promptView.isAutomaticDashSubstitutionEnabled = false
        promptView.isAutomaticTextReplacementEnabled = false
        promptView.textContainerInset = NSSize(width: 4, height: 4)
        let promptScroll = NSScrollView()
        promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .bezelBorder
        promptScroll.documentView = promptView

        let modelLabel = NSTextField(labelWithString: "模型")
        let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let aliases = modelAliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var selectable = Array(NSOrderedSet(array: aliases)) as? [String] ?? aliases
        if let saved = draft.modelAlias?.trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty,
           !selectable.contains(saved) {
            selectable.append(saved)
        }
        if selectable.isEmpty {
            let item = NSMenuItem(title: "请先在「厂家」里配置可用模型", action: nil, keyEquivalent: "")
            item.isEnabled = false
            modelPopup.menu?.addItem(item)
        } else {
            for alias in selectable {
                let title = aliases.contains(alias) ? alias : "\(alias)（当前不可用）"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.representedObject = alias
                modelPopup.menu?.addItem(item)
            }
            if let saved = draft.modelAlias,
               let item = modelPopup.menu?.items.first(where: { $0.representedObject as? String == saved }) {
                modelPopup.select(item)
            }
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        for view in [nameLabel, nameField, promptLabel, promptScroll, modelLabel, modelPopup] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
        }
        NSLayoutConstraint.activate([
            nameField.widthAnchor.constraint(equalToConstant: 360),
            promptScroll.widthAnchor.constraint(equalToConstant: 360),
            promptScroll.heightAnchor.constraint(equalToConstant: 96),
            modelPopup.widthAnchor.constraint(equalToConstant: 360)
        ])
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 220)
        alert.accessoryView = stack

        let saveButton = alert.buttons[0]
        func updateSaveButton() {
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = promptView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let alias = modelPopup.selectedItem?.representedObject as? String
            saveButton.isEnabled = !name.isEmpty && !prompt.isEmpty && alias != nil
        }
        let observer = ModelAutomationNameObserver(onChange: updateSaveButton)
        nameField.delegate = observer
        promptView.delegate = observer
        modelPopup.target = observer
        modelPopup.action = #selector(ModelAutomationNameObserver.popupChanged)
        updateSaveButton()

        let response = withExtendedLifetime(observer) {
            alert.runModalFocusingFirstTextField()
        }
        nameField.delegate = nil
        promptView.delegate = nil
        modelPopup.target = nil
        let savedDraft = ModelAutomationDraft(
            id: draft.id,
            name: nameField.stringValue,
            prompt: promptView.string,
            modelAlias: modelPopup.selectedItem?.representedObject as? String
        )
        switch response {
        case .alertFirstButtonReturn:
            return .save(savedDraft)
        case .alertThirdButtonReturn where isEditing:
            return .delete
        default:
            return .cancel
        }
    }
}

@MainActor
private final class ModelAutomationNameObserver: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange()
    }

    func textDidChange(_ notification: Notification) {
        onChange()
    }

    @objc func popupChanged() {
        onChange()
    }
}
