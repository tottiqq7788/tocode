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
        alert.informativeText = "点击快捷键框后输入键盘组合，或把源快捷键映射为 Tocode 功能或系统桌面切换。"
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
        let targetEditor = KeyboardMappingTargetEditor(target: draft.target)

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
        alert.window.initialFirstResponder = nameField

        let response = withExtendedLifetime(observer) {
            alert.runModal()
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

    let view: NSView
    var onChange: (() -> Void)?

    private let segment = NSSegmentedControl(
        labels: ["映射快捷键", "映射功能"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let recorder: ShortcutRecorderView
    private let shortcutPage = NSView()
    private let actionPage = NSView()
    private let actionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var selectedAction: KeyboardMappingAction
    private var actionItems: [KeyboardMappingAction: NSMenuItem] = [:]

    init(target: KeyboardShortcutMappingTarget?) {
        if case .action(let action)? = target {
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

        let stack = NSStackView()
        view = stack
        super.init()

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7

        segment.segmentDistribution = .fillEqually
        segment.target = self
        segment.action = #selector(segmentChanged(_:))
        segment.toolTip = "选择目标是另一个组合键，还是一个 Tocode 功能"

        recorder.toolTip = "点击后输入替换后的快捷键"
        recorder.onChange = { [weak self] _ in self?.onChange?() }
        shortcutPage.addSubview(recorder)

        populateActionPopup()
        actionPopup.target = self
        actionPopup.action = #selector(actionPopupChanged(_:))
        actionPopup.toolTip = "按右键菜单分组选择一次性动作或开关切换"
        actionPage.addSubview(actionPopup)

        let container = NSView()
        container.addSubview(shortcutPage)
        container.addSubview(actionPage)

        for subview in [segment, container] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(subview)
        }
        for subview in [shortcutPage, actionPage, recorder, actionPopup] {
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
            actionPopup.heightAnchor.constraint(equalToConstant: 28)
        ])

        updatePages()
    }

    /// 当前分段下的目标；快捷键页未录入时返回 nil，用于禁用保存。
    var target: KeyboardShortcutMappingTarget? {
        if segment.selectedSegment == Self.actionSegment {
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
        segment.target = nil
        actionPopup.target = nil
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        updatePages()
        onChange?()
    }

    @objc private func actionPopupChanged(_ sender: NSPopUpButton) {
        guard
            let rawValue = sender.selectedItem?.representedObject as? String,
            let action = KeyboardMappingAction(rawValue: rawValue)
        else {
            return
        }
        selectedAction = action
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
                item.toolTip = "命中源快捷键后执行「\(group.title) → \(action.title)」"
                menu.addItem(item)
                actionItems[action] = item
            }
        }
        actionPopup.menu = menu
        if let item = actionItems[selectedAction] {
            actionPopup.select(item)
        }
    }

    private func updatePages() {
        let isAction = segment.selectedSegment == Self.actionSegment
        shortcutPage.isHidden = isAction
        actionPage.isHidden = !isAction
        // 隐藏页不得继续持有键盘焦点，否则按键会写进看不见的录入框。
        if isAction, recorder.window?.firstResponder === recorder {
            recorder.window?.makeFirstResponder(nil)
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
