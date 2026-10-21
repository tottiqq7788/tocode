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
        isEditing: Bool,
        automations: [ModelAutomation] = []
    ) -> KeyboardShortcutMappingPromptResult {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = isEditing ? "编辑键盘映射" : "新增键盘映射"
        alert.informativeText = "点击快捷键框后输入键盘组合，或把源快捷键映射为 Tocode 功能、打开网址或一个自动化。"
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

        let targetLabel = NSTextField(labelWithString: "目标")
        let targetEditor = KeyboardMappingTargetEditor(
            target: draft.target,
            automations: automations
        )

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
            targetEditor.view
        ] {
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
        }
        NSLayoutConstraint.activate([
            nameField.widthAnchor.constraint(equalToConstant: 320),
            sourceRecorder.widthAnchor.constraint(equalToConstant: 320),
            sourceRecorder.heightAnchor.constraint(equalToConstant: 48),
            targetEditor.view.widthAnchor.constraint(equalToConstant: 320)
        ])
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 264)
        alert.accessoryView = stack

        let saveButton = alert.buttons[0]
        func updateSaveButton() {
            saveButton.isEnabled =
                !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && sourceRecorder.shortcut != nil
                && targetEditor.target != nil
        }

        let observer = KeyboardMappingNameObserver(onChange: updateSaveButton)
        nameField.delegate = observer
        sourceRecorder.onChange = { _ in updateSaveButton() }
        targetEditor.onChange = updateSaveButton
        updateSaveButton()

        let response = withExtendedLifetime(observer) {
            alert.runModalFocusingFirstTextField()
        }
        nameField.delegate = nil
        sourceRecorder.onChange = nil
        let target = targetEditor.target
        targetEditor.detach()
        switch response {
        case .alertFirstButtonReturn:
            return .save(
                KeyboardShortcutMappingDraft(
                    id: draft.id,
                    name: nameField.stringValue,
                    source: sourceRecorder.shortcut,
                    target: target
                )
            )
        case .alertThirdButtonReturn where isEditing:
            return .delete
        default:
            return .cancel
        }
    }
}

/// 目标区：分段控件在「映射快捷键」与「映射功能」之间切换。
/// 两页共存于同一固定高度容器，来回切换不会丢失已填内容，也不改变弹窗尺寸。
@MainActor
final class KeyboardMappingTargetEditor: NSObject {
    static let width: CGFloat = 320
    private static let pageHeight: CGFloat = 76
    private static let recorderHeight: CGFloat = 48
    private static let actionSegment = 1
    private static let automationSegment = 2

    let view: NSView
    var onChange: (() -> Void)?

    private let segment = NSSegmentedControl(
        labels: ["映射快捷键", "映射功能", "自动化"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let recorder: ShortcutRecorderView
    private let shortcutPage = NSView()
    private let actionPage = NSView()
    private let automationPage = NSView()
    private let actionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let automationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let urlField = NSTextField(string: "")
    private let urlObserver = MappedURLFieldObserver()
    private var selectedAction: KeyboardMappingAction
    private var openURLSelected = false
    private var openURLItem: NSMenuItem?
    private var actionItems: [KeyboardMappingAction: NSMenuItem] = [:]
    private let extraActions: [RemoteMappingExtra]
    private var extraItems: [String: NSMenuItem] = [:]
    private var selectedExtra: String?
    private let actionTriggerPhrase: String
    private let automations: [ModelAutomation]
    private var selectedAutomationID: UUID?
    private static let openURLRepresented = "tocode.openURL"

    init(
        target: KeyboardShortcutMappingTarget?,
        actionTriggerPhrase: String = "命中源快捷键后",
        automations: [ModelAutomation] = [],
        extraActions: [RemoteMappingExtra] = [],
        selectedExtra: String? = nil
    ) {
        self.actionTriggerPhrase = actionTriggerPhrase
        self.automations = automations
        self.extraActions = extraActions
        self.selectedExtra = selectedExtra
        if case .automation(let id)? = target {
            recorder = ShortcutRecorderView(shortcut: nil)
            selectedAction = .blackout
            selectedAutomationID = id
            segment.selectedSegment = Self.automationSegment
        } else if case .openURL(let raw)? = target {
            recorder = ShortcutRecorderView(shortcut: nil)
            selectedAction = .blackout
            openURLSelected = true
            urlField.stringValue = raw
            segment.selectedSegment = Self.actionSegment
        } else if case .action(let action)? = target {
            recorder = ShortcutRecorderView(shortcut: nil)
            selectedAction = action
            segment.selectedSegment = Self.actionSegment
        } else {
            var existing: RecordedShortcut?
            if case .shortcut(let shortcut)? = target {
                existing = shortcut
            }
            recorder = ShortcutRecorderView(shortcut: existing)
            selectedAction = KeyboardMappingAction.allCases[0]
            segment.selectedSegment = 0
        }
        if selectedExtra != nil {
            segment.selectedSegment = Self.actionSegment
        }

        let stack = NSStackView()
        view = stack
        super.init()

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7

        segment.segmentDistribution = .fillEqually
        segment.target = self
        segment.action = #selector(segmentChanged(_:))
        segment.toolTip = "选择目标是另一个组合键、一个 Tocode 功能，或一个已保存的自动化"

        recorder.toolTip = "点击后输入替换后的快捷键"
        recorder.onChange = { [weak self] _ in self?.onChange?() }
        shortcutPage.addSubview(recorder)

        populateActionPopup()
        populateAutomationPopup()
        actionPopup.target = self
        actionPopup.action = #selector(actionPopupChanged(_:))
        automationPopup.target = self
        automationPopup.action = #selector(automationPopupChanged(_:))
        actionPopup.toolTip = "按右键菜单分组选择一次性动作、开关切换或打开网址"
        urlField.placeholderString = "https:// 或其它带协议的网址"
        urlField.toolTip = "去掉空白后须包含协议，例如 https://、file:// 或 mailto:"
        urlField.delegate = urlObserver
        urlObserver.onChange = { [weak self] in self?.onChange?() }
        actionPage.addSubview(actionPopup)
        actionPage.addSubview(urlField)
        automationPage.addSubview(automationPopup)

        let container = NSView()
        container.addSubview(shortcutPage)
        container.addSubview(actionPage)
        container.addSubview(automationPage)

        for subview in [segment, container] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(subview)
        }
        for subview in [shortcutPage, actionPage, automationPage, recorder, actionPopup, automationPopup, urlField] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            segment.widthAnchor.constraint(equalToConstant: Self.width),
            container.widthAnchor.constraint(equalToConstant: Self.width),
            container.heightAnchor.constraint(equalToConstant: Self.pageHeight),
            shortcutPage.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            shortcutPage.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            shortcutPage.topAnchor.constraint(equalTo: container.topAnchor),
            shortcutPage.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            actionPage.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            actionPage.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            actionPage.topAnchor.constraint(equalTo: container.topAnchor),
            actionPage.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            recorder.leadingAnchor.constraint(equalTo: shortcutPage.leadingAnchor),
            recorder.trailingAnchor.constraint(equalTo: shortcutPage.trailingAnchor),
            recorder.topAnchor.constraint(equalTo: shortcutPage.topAnchor),
            recorder.heightAnchor.constraint(equalToConstant: Self.recorderHeight),
            actionPopup.leadingAnchor.constraint(equalTo: actionPage.leadingAnchor),
            actionPopup.trailingAnchor.constraint(equalTo: actionPage.trailingAnchor),
            actionPopup.topAnchor.constraint(equalTo: actionPage.topAnchor),
            actionPopup.heightAnchor.constraint(equalToConstant: 28),
            urlField.leadingAnchor.constraint(equalTo: actionPage.leadingAnchor),
            urlField.trailingAnchor.constraint(equalTo: actionPage.trailingAnchor),
            urlField.topAnchor.constraint(equalTo: actionPopup.bottomAnchor, constant: 6),
            urlField.heightAnchor.constraint(equalToConstant: 24),
            automationPage.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            automationPage.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            automationPage.topAnchor.constraint(equalTo: container.topAnchor),
            automationPage.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            automationPopup.leadingAnchor.constraint(equalTo: automationPage.leadingAnchor),
            automationPopup.trailingAnchor.constraint(equalTo: automationPage.trailingAnchor),
            automationPopup.topAnchor.constraint(equalTo: automationPage.topAnchor),
            automationPopup.heightAnchor.constraint(equalToConstant: 28)
        ])

        updatePages()
    }

    var selectedExtraID: String? {
        guard segment.selectedSegment == Self.actionSegment else { return nil }
        return selectedExtra
    }

    /// 当前分段下的目标；快捷键页未录入时返回 nil，用于禁用保存。
    var target: KeyboardShortcutMappingTarget? {
        if segment.selectedSegment == Self.automationSegment {
            guard
                let rawID = automationPopup.selectedItem?.representedObject as? String,
                let id = UUID(uuidString: rawID),
                automations.contains(where: { $0.id == id })
            else {
                return nil
            }
            return .automation(id)
        }
        if segment.selectedSegment == Self.actionSegment {
            if selectedExtra != nil { return nil }
            if openURLSelected {
                guard let url = MappedURL.normalized(urlField.stringValue) else { return nil }
                return .openURL(url)
            }
            if let rawValue = actionPopup.selectedItem?.representedObject as? String,
                let action = KeyboardMappingAction(rawValue: rawValue)
            {
                return .action(action)
            }
            return .action(selectedAction)
        }
        guard let shortcut = recorder.shortcut else { return nil }
        return .shortcut(shortcut)
    }

    func detach() {
        onChange = nil
        recorder.onChange = nil
        urlObserver.onChange = nil
        urlField.delegate = nil
        segment.target = nil
        actionPopup.target = nil
        automationPopup.target = nil
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        updatePages()
        onChange?()
    }

    @objc private func actionPopupChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String else { return }
        if rawValue.hasPrefix("remote-extra:") {
            openURLSelected = false
            selectedExtra = String(rawValue.dropFirst("remote-extra:".count))
            updateURLField()
            onChange?()
            return
        }
        selectedExtra = nil
        if rawValue == Self.openURLRepresented {
            openURLSelected = true
            updateURLField()
            onChange?()
            return
        }
        guard let action = KeyboardMappingAction(rawValue: rawValue) else { return }
        openURLSelected = false
        selectedAction = action
        updateURLField()
        onChange?()
    }

    @objc private func automationPopupChanged(_ sender: NSPopUpButton) {
        onChange?()
    }

    private func populateActionPopup() {
        let menu = NSMenu()
        // 扁平列表：分组标题禁用，选项一级可选。
        // NSPopUpButton 的子菜单选中项不会成为 selectedItem，保存时会悄悄落回默认的「向左切换桌面」。
        for group in KeyboardMappingActionGroup.allCases {
            let header = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for action in group.actions {
                let item = NSMenuItem(
                    title: action.title,
                    action: nil,
                    keyEquivalent: ""
                )
                item.representedObject = action.rawValue
                item.indentationLevel = 1
                item.image = NSImage(
                    systemSymbolName: action.menuSymbolName,
                    accessibilityDescription: action.title
                )
                item.toolTip = "\(actionTriggerPhrase)执行「\(group.title) → \(action.title)」"
                menu.addItem(item)
                actionItems[action] = item
            }
            if group == .tools {
                let item = NSMenuItem(title: "打开网址", action: nil, keyEquivalent: "")
                item.representedObject = Self.openURLRepresented
                item.indentationLevel = 1
                item.image = NSImage(systemSymbolName: "link", accessibilityDescription: "打开网址")
                item.toolTip = "\(actionTriggerPhrase)用系统默认方式打开所填网址"
                menu.addItem(item)
                openURLItem = item
            }
        }
        if !extraActions.isEmpty {
            let header = NSMenuItem(title: "遥控", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for extra in extraActions {
                let item = NSMenuItem(title: extra.title, action: nil, keyEquivalent: "")
                item.representedObject = "remote-extra:\(extra.id)"
                item.indentationLevel = 1
                item.image = NSImage(systemSymbolName: extra.symbol, accessibilityDescription: extra.title)
                item.toolTip = "点一下执行「\(extra.title)」"
                menu.addItem(item)
                extraItems[extra.id] = item
            }
        }
        actionPopup.menu = menu
        if let selectedExtra, let item = extraItems[selectedExtra] {
            actionPopup.select(item)
        } else if openURLSelected, let openURLItem {
            actionPopup.select(openURLItem)
        } else if let item = actionItems[selectedAction] {
            actionPopup.select(item)
        }
    }

    private func populateAutomationPopup() {
        let menu = NSMenu()
        let sorted = automations.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if sorted.isEmpty {
            let item = NSMenuItem(
                title: "请先在「模型 → 自动化」新增",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }
        for automation in sorted {
            let item = NSMenuItem(title: automation.name, action: nil, keyEquivalent: "")
            item.representedObject = automation.id.uuidString
            item.toolTip = "\(actionTriggerPhrase)读取选中文字，调用「\(automation.name)」，并把结果粘贴回去"
            menu.addItem(item)
        }
        if let selectedAutomationID, !sorted.contains(where: { $0.id == selectedAutomationID }) {
            let missing = NSMenuItem(title: "自动化不存在", action: nil, keyEquivalent: "")
            missing.isEnabled = false
            menu.addItem(missing)
        }
        automationPopup.menu = menu
        if let selectedAutomationID,
           let item = menu.items.first(where: {
               $0.representedObject as? String == selectedAutomationID.uuidString
           }) {
            automationPopup.select(item)
        } else if let missing = menu.items.first(where: { $0.title == "自动化不存在" }) {
            automationPopup.select(missing)
        }
    }

    private func updatePages() {
        let segmentIndex = segment.selectedSegment
        shortcutPage.isHidden = segmentIndex != 0
        actionPage.isHidden = segmentIndex != Self.actionSegment
        automationPage.isHidden = segmentIndex != Self.automationSegment
        updateURLField()
        // 隐藏页不得继续持有键盘焦点，否则按键会写进看不见的录入框。
        if segmentIndex != 0, recorder.window?.firstResponder === recorder {
            recorder.window?.makeFirstResponder(nil)
        }
        if segmentIndex != Self.actionSegment || !openURLSelected,
           urlField.window?.firstResponder === urlField.currentEditor() {
            urlField.window?.makeFirstResponder(nil)
        }
    }

    private func updateURLField() {
        let visible = segment.selectedSegment == Self.actionSegment && openURLSelected
        urlField.isHidden = !visible
    }
}

@MainActor
private final class MappedURLFieldObserver: NSObject, NSTextFieldDelegate {
    var onChange: (() -> Void)?

    func controlTextDidChange(_ obj: Notification) {
        onChange?()
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
