import AppKit

enum MacTimerPromptResult {
    case save(MacTimerDraft)
    case delete
    case cancel
}

enum MacTimerPromptMode: Equatable {
    case create
    case editIdle
    case editRunning

    var title: String {
        switch self {
        case .create:
            return "新增定时任务"
        case .editIdle, .editRunning:
            return "编辑定时任务"
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .create, .editIdle:
            return "启动"
        case .editRunning:
            return "保存"
        }
    }

    var showsDelete: Bool {
        switch self {
        case .create:
            return false
        case .editIdle, .editRunning:
            return true
        }
    }
}

@MainActor
enum MacTimerPrompt {
    static func prompt(
        draft: MacTimerDraft,
        mode: MacTimerPromptMode
    ) -> MacTimerPromptResult {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = mode.title
        alert.informativeText = "设置倒计时分钟与到点要执行的事项。事项目录与键盘映射相同。"
        alert.addButton(withTitle: mode.primaryButtonTitle)
        alert.addButton(withTitle: "取消")
        if mode.showsDelete {
            let deleteButton = alert.addButton(withTitle: "删除")
            deleteButton.contentTintColor = .systemRed
        }

        let nameLabel = NSTextField(labelWithString: "名称")
        let nameField = NSTextField(string: draft.name)
        nameField.placeholderString = "例如：休息提醒"

        let durationLabel = NSTextField(labelWithString: "分钟")
        let durationField = NSTextField(string: draft.durationMinutesText)
        durationField.placeholderString = "1…10080"

        let targetLabel = NSTextField(labelWithString: "事项")
        let targetEditor = KeyboardMappingTargetEditor(
            target: draft.target,
            actionTriggerPhrase: "到点后"
        )

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        for view in [
            nameLabel,
            nameField,
            durationLabel,
            durationField,
            targetLabel,
            targetEditor.view
        ] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
        }
        NSLayoutConstraint.activate([
            nameField.widthAnchor.constraint(equalToConstant: 320),
            durationField.widthAnchor.constraint(equalToConstant: 320),
            targetEditor.view.widthAnchor.constraint(equalToConstant: 320)
        ])
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 236)
        alert.accessoryView = stack

        let saveButton = alert.buttons[0]
        func updateSaveButton() {
            let nameOK = !nameField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let durationOK = MacTimerRemaining.parseMinutes(durationField.stringValue) != nil
            saveButton.isEnabled = nameOK && durationOK && targetEditor.target != nil
        }

        let observer = MacTimerFieldObserver(onChange: updateSaveButton)
        nameField.delegate = observer
        durationField.delegate = observer
        targetEditor.onChange = updateSaveButton
        updateSaveButton()

        let response = withExtendedLifetime(observer) {
            alert.runModalFocusingFirstTextField()
        }
        nameField.delegate = nil
        durationField.delegate = nil
        let target = targetEditor.target
        targetEditor.detach()
        switch response {
        case .alertFirstButtonReturn:
            return .save(
                MacTimerDraft(
                    id: draft.id,
                    name: nameField.stringValue,
                    durationMinutesText: durationField.stringValue,
                    target: target
                )
            )
        case .alertThirdButtonReturn where mode.showsDelete:
            return .delete
        default:
            return .cancel
        }
    }
}

@MainActor
private final class MacTimerFieldObserver: NSObject, NSTextFieldDelegate {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange()
    }
}
