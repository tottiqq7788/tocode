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
    fileprivate static let width: CGFloat = 320
    fileprivate static let onceSegment = 0
    fileprivate static let cronSegment = 1

    static func prompt(
        draft: MacTimerDraft,
        mode: MacTimerPromptMode
    ) -> MacTimerPromptResult {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = mode.title
        alert.informativeText = "选择一次性倒计时或 cron 表达式，并配置到点事项。"
        alert.addButton(withTitle: mode.primaryButtonTitle)
        alert.addButton(withTitle: "取消")
        if mode.showsDelete {
            let deleteButton = alert.addButton(withTitle: "删除")
            deleteButton.contentTintColor = .systemRed
        }

        let nameLabel = NSTextField(labelWithString: "名称")
        let nameField = NSTextField(string: draft.name)
        nameField.placeholderString = "例如：休息提醒"

        let scheduleLabel = NSTextField(labelWithString: "时间")
        let segment = NSSegmentedControl(
            labels: ["一次性", "cron"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        segment.segmentDistribution = .fillEqually
        segment.selectedSegment = draft.kind == .cron ? cronSegment : onceSegment

        let oncePage = NSView()
        let hoursStepper = MacTimerStepperField(
            label: "小时",
            valueText: draft.hoursText,
            minValue: 0,
            maxValue: MacTimerRemaining.maxHours
        )
        let minutesStepper = MacTimerStepperField(
            label: "分钟",
            valueText: draft.minutesText,
            minValue: 0,
            maxValue: MacTimerRemaining.maxFieldMinutes
        )
        let onceRow = NSStackView(views: [hoursStepper.view, minutesStepper.view])
        onceRow.orientation = .horizontal
        onceRow.spacing = 12
        onceRow.alignment = .centerY
        onceRow.translatesAutoresizingMaskIntoConstraints = false
        oncePage.addSubview(onceRow)

        let cronPage = NSView()
        let cronField = NSTextField(string: draft.cronExpression)
        cronField.placeholderString = "分 时 日 月 周，例如 */5 * * * *"
        let nextLabel = NSTextField(labelWithString: "")
        nextLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        nextLabel.textColor = .secondaryLabelColor
        nextLabel.lineBreakMode = .byTruncatingTail
        cronField.translatesAutoresizingMaskIntoConstraints = false
        nextLabel.translatesAutoresizingMaskIntoConstraints = false
        cronPage.addSubview(cronField)
        cronPage.addSubview(nextLabel)

        let scheduleContainer = NSView()
        scheduleContainer.addSubview(oncePage)
        scheduleContainer.addSubview(cronPage)
        oncePage.translatesAutoresizingMaskIntoConstraints = false
        cronPage.translatesAutoresizingMaskIntoConstraints = false
        scheduleContainer.translatesAutoresizingMaskIntoConstraints = false

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
            scheduleLabel,
            segment,
            scheduleContainer,
            targetLabel,
            targetEditor.view
        ] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
        }

        NSLayoutConstraint.activate([
            nameField.widthAnchor.constraint(equalToConstant: width),
            segment.widthAnchor.constraint(equalToConstant: width),
            scheduleContainer.widthAnchor.constraint(equalToConstant: width),
            scheduleContainer.heightAnchor.constraint(equalToConstant: 56),
            oncePage.leadingAnchor.constraint(equalTo: scheduleContainer.leadingAnchor),
            oncePage.trailingAnchor.constraint(equalTo: scheduleContainer.trailingAnchor),
            oncePage.topAnchor.constraint(equalTo: scheduleContainer.topAnchor),
            oncePage.bottomAnchor.constraint(equalTo: scheduleContainer.bottomAnchor),
            cronPage.leadingAnchor.constraint(equalTo: scheduleContainer.leadingAnchor),
            cronPage.trailingAnchor.constraint(equalTo: scheduleContainer.trailingAnchor),
            cronPage.topAnchor.constraint(equalTo: scheduleContainer.topAnchor),
            cronPage.bottomAnchor.constraint(equalTo: scheduleContainer.bottomAnchor),
            onceRow.leadingAnchor.constraint(equalTo: oncePage.leadingAnchor),
            onceRow.trailingAnchor.constraint(equalTo: oncePage.trailingAnchor),
            onceRow.centerYAnchor.constraint(equalTo: oncePage.centerYAnchor),
            cronField.leadingAnchor.constraint(equalTo: cronPage.leadingAnchor),
            cronField.trailingAnchor.constraint(equalTo: cronPage.trailingAnchor),
            cronField.topAnchor.constraint(equalTo: cronPage.topAnchor),
            cronField.heightAnchor.constraint(equalToConstant: 22),
            nextLabel.leadingAnchor.constraint(equalTo: cronPage.leadingAnchor),
            nextLabel.trailingAnchor.constraint(equalTo: cronPage.trailingAnchor),
            nextLabel.topAnchor.constraint(equalTo: cronField.bottomAnchor, constant: 4),
            targetEditor.view.widthAnchor.constraint(equalToConstant: width)
        ])
        stack.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        alert.accessoryView = stack

        let saveButton = alert.buttons[0]
        let bridge = MacTimerPromptBridge(
            nameField: nameField,
            segment: segment,
            hoursStepper: hoursStepper,
            minutesStepper: minutesStepper,
            cronField: cronField,
            nextLabel: nextLabel,
            oncePage: oncePage,
            cronPage: cronPage,
            targetEditor: targetEditor,
            saveButton: saveButton
        )
        bridge.refresh()

        let response = withExtendedLifetime(bridge) {
            alert.runModalFocusingFirstTextField()
        }
        let resultDraft = bridge.makeDraft(id: draft.id)
        bridge.detach()
        switch response {
        case .alertFirstButtonReturn:
            return .save(resultDraft)
        case .alertThirdButtonReturn where mode.showsDelete:
            return .delete
        default:
            return .cancel
        }
    }
}

@MainActor
private final class MacTimerPromptBridge: NSObject, NSTextFieldDelegate {
    private let nameField: NSTextField
    private let segment: NSSegmentedControl
    private let hoursStepper: MacTimerStepperField
    private let minutesStepper: MacTimerStepperField
    private let cronField: NSTextField
    private let nextLabel: NSTextField
    private let oncePage: NSView
    private let cronPage: NSView
    private let targetEditor: KeyboardMappingTargetEditor
    private let saveButton: NSButton

    init(
        nameField: NSTextField,
        segment: NSSegmentedControl,
        hoursStepper: MacTimerStepperField,
        minutesStepper: MacTimerStepperField,
        cronField: NSTextField,
        nextLabel: NSTextField,
        oncePage: NSView,
        cronPage: NSView,
        targetEditor: KeyboardMappingTargetEditor,
        saveButton: NSButton
    ) {
        self.nameField = nameField
        self.segment = segment
        self.hoursStepper = hoursStepper
        self.minutesStepper = minutesStepper
        self.cronField = cronField
        self.nextLabel = nextLabel
        self.oncePage = oncePage
        self.cronPage = cronPage
        self.targetEditor = targetEditor
        self.saveButton = saveButton
        super.init()
        nameField.delegate = self
        cronField.delegate = self
        segment.target = self
        segment.action = #selector(segmentChanged)
        hoursStepper.onChange = { [weak self] in self?.refresh() }
        minutesStepper.onChange = { [weak self] in self?.refresh() }
        targetEditor.onChange = { [weak self] in self?.refresh() }
    }

    func refresh() {
        let isCron = segment.selectedSegment == MacTimerPrompt.cronSegment
        oncePage.isHidden = isCron
        cronPage.isHidden = !isCron
        if isCron {
            updateCronPreview()
        }
        let nameOK = !nameField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let scheduleOK: Bool
        if isCron {
            if let schedule = MacCronSchedule.parse(cronField.stringValue),
               schedule.nextFire(after: Date()) != nil
            {
                scheduleOK = true
            } else {
                scheduleOK = false
            }
        } else {
            scheduleOK = MacTimerRemaining.parseOnceDuration(
                hoursText: hoursStepper.valueText,
                minutesText: minutesStepper.valueText
            ) != nil
        }
        saveButton.isEnabled = nameOK && scheduleOK && targetEditor.target != nil
    }

    func makeDraft(id: UUID?) -> MacTimerDraft {
        MacTimerDraft(
            id: id,
            name: nameField.stringValue,
            kind: segment.selectedSegment == MacTimerPrompt.cronSegment ? .cron : .once,
            hoursText: hoursStepper.valueText,
            minutesText: minutesStepper.valueText,
            cronExpression: cronField.stringValue,
            target: targetEditor.target
        )
    }

    func detach() {
        nameField.delegate = nil
        cronField.delegate = nil
        segment.target = nil
        hoursStepper.onChange = nil
        minutesStepper.onChange = nil
        targetEditor.detach()
    }

    func controlTextDidChange(_ obj: Notification) {
        refresh()
    }

    @objc private func segmentChanged() {
        refresh()
    }

    private func updateCronPreview() {
        let expression = cronField.stringValue
        if let schedule = MacCronSchedule.parse(expression),
           let next = schedule.nextFire(after: Date())
        {
            nextLabel.stringValue =
                "下次执行：\(MacTimerRemaining.formatNextFire(next))"
            nextLabel.textColor = .secondaryLabelColor
        } else if expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nextLabel.stringValue = "输入 5 段 cron 后显示下次执行时间"
            nextLabel.textColor = .tertiaryLabelColor
        } else {
            nextLabel.stringValue = "表达式无效"
            nextLabel.textColor = .systemRed
        }
    }
}

@MainActor
private final class MacTimerStepperField: NSObject, NSTextFieldDelegate {
    let view: NSView
    var onChange: (() -> Void)?

    private let field: NSTextField
    private let minusButton: NSButton
    private let plusButton: NSButton
    private let minValue: Int
    private let maxValue: Int

    var valueText: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    init(label: String, valueText: String, minValue: Int, maxValue: Int) {
        self.minValue = minValue
        self.maxValue = maxValue
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field = NSTextField(string: valueText)
        field.alignment = .center
        minusButton = NSButton(title: "−", target: nil, action: nil)
        plusButton = NSButton(title: "+", target: nil, action: nil)
        for button in [minusButton, plusButton] {
            button.bezelStyle = .flexiblePush
            button.setButtonType(.momentaryPushIn)
            button.controlSize = .small
        }

        let controls = NSStackView(views: [minusButton, field, plusButton])
        controls.orientation = .horizontal
        controls.spacing = 4
        controls.alignment = .centerY

        let stack = NSStackView(views: [title, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        view = stack
        super.init()

        field.delegate = self
        minusButton.target = self
        minusButton.action = #selector(decrement)
        plusButton.target = self
        plusButton.action = #selector(increment)
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: 44),
            minusButton.widthAnchor.constraint(equalToConstant: 28),
            plusButton.widthAnchor.constraint(equalToConstant: 28)
        ])
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?()
    }

    @objc private func decrement() {
        adjust(by: -1)
    }

    @objc private func increment() {
        adjust(by: 1)
    }

    private func adjust(by delta: Int) {
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = Int(trimmed) ?? 0
        let next = min(max(current + delta, minValue), maxValue)
        field.stringValue = String(next)
        onChange?()
    }
}
