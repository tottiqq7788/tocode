import AppKit
import Foundation

enum TogentRolePromptResult {
    case save(TogentRoleDraft)
    case openWorkspace(TogentRoleDraft)
    case cancel
}

protocol TogentWorkspaceOpening {
    func open(_ url: URL) -> Bool
}

struct SystemTogentWorkspaceOpener: TogentWorkspaceOpening {
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

func openTogentWorkspace(
    at persistedPath: String,
    fileManager: FileManager = .default,
    opener: TogentWorkspaceOpening
) -> Bool {
    let url = URL(fileURLWithPath: persistedPath, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        return false
    }
    return opener.open(url)
}

enum TogentPrompts {
    static let creationTabTitles = ["从零新增", "拷贝角色"]

    static func roleForm(
        draft: TogentRoleDraft,
        models: [TogentModelOption],
        isEditing: Bool,
        copyOptions: [TogentRoleCopyOption] = []
    ) -> TogentRolePromptResult {
        if isEditing {
            return editRoleForm(draft: draft, models: models)
        }
        return createRoleForm(
            draft: draft,
            models: models,
            copyOptions: copyOptions
        )
    }

    private static func editRoleForm(
        draft: TogentRoleDraft,
        models: [TogentModelOption]
    ) -> TogentRolePromptResult {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "编辑 Togent 角色"
        alert.informativeText = models.isEmpty
            ? "当前没有健康的模型中转可供选择。请先配置“模型 → 厂家”。"
            : "角色名称使用英文标识；微信普通消息只会发送给当前勾选的一个角色。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "打开文件位置")
        let fields = TogentRoleFormFields(
            draft: draft,
            models: models,
            automaticPath: false
        )
        alert.accessoryView = fields.view
        alert.buttons.first?.isEnabled = !models.isEmpty
            || draft.publishedModelID.isEmpty
        let response = withExtendedLifetime(fields) {
            alert.runModalFocusingFirstTextField()
        }
        guard response == .alertFirstButtonReturn
                || response == .alertThirdButtonReturn else {
            return .cancel
        }
        let candidate = fields.draft
        if response == .alertThirdButtonReturn {
            return .openWorkspace(candidate)
        }
        return .save(candidate)
    }

    private static func createRoleForm(
        draft: TogentRoleDraft,
        models: [TogentModelOption],
        copyOptions: [TogentRoleCopyOption]
    ) -> TogentRolePromptResult {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "新增 Togent 角色"
        alert.informativeText = models.isEmpty
            ? "当前没有健康的模型中转可供选择。请先配置“模型 → 厂家”。"
            : "名称须以英文字母开头；默认项目路径会随名称变化。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")

        let tabView = NSTabView(frame: NSRect(x: 0, y: 0, width: 580, height: 390))
        let blankFields = TogentRoleFormFields(
            draft: draft,
            models: models,
            automaticPath: TogentRolePathBinding.isManagedDefaultWorkspace(
                roleName: draft.name,
                workspacePath: draft.workspacePath
            )
        )
        let blankContainer = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 350))
        blankFields.view.frame.origin = NSPoint(x: 10, y: 5)
        blankContainer.addSubview(blankFields.view)
        let blankItem = NSTabViewItem(identifier: "blank")
        blankItem.label = creationTabTitles[0]
        blankItem.view = blankContainer
        tabView.addTabViewItem(blankItem)

        var copyFields: TogentRoleFormFields?
        var copyController: TogentRoleCopySourceController?
        if let first = copyOptions.first {
            let fields = TogentRoleFormFields(
                draft: first.draft,
                models: models,
                automaticPath: true
            )
            let copyContainer = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 350))
            fields.view.frame.origin = NSPoint(x: 10, y: 0)
            copyContainer.addSubview(fields.view)
            let sourcePopup = NSPopUpButton(
                frame: NSRect(x: 114, y: 332, width: 446, height: 28),
                pullsDown: false
            )
            for option in copyOptions {
                sourcePopup.addItem(withTitle: option.sourceRoleName)
                sourcePopup.lastItem?.representedObject = option.sourceRoleID.uuidString
            }
            copyContainer.addSubview(label("源角色", y: 338))
            copyContainer.addSubview(sourcePopup)
            let controller = TogentRoleCopySourceController(
                popup: sourcePopup,
                options: copyOptions,
                fields: fields
            )
            sourcePopup.target = controller
            sourcePopup.action = #selector(TogentRoleCopySourceController.sourceChanged(_:))
            let copyItem = NSTabViewItem(identifier: "copy")
            copyItem.label = creationTabTitles[1]
            copyItem.view = copyContainer
            tabView.addTabViewItem(copyItem)
            copyFields = fields
            copyController = controller
        }

        alert.accessoryView = tabView
        alert.buttons.first?.isEnabled = !models.isEmpty
        var retained: [AnyObject] = [blankFields]
        if let copyFields { retained.append(copyFields) }
        if let copyController { retained.append(copyController) }
        let response = withExtendedLifetime(retained) {
            alert.runModalFocusingFirstTextField()
        }
        guard response == .alertFirstButtonReturn else {
            return .cancel
        }
        if (tabView.selectedTabViewItem?.identifier as? String) == "copy",
           let copyFields {
            return .save(copyFields.draft)
        }
        return .save(blankFields.draft)
    }

    static func modelMenuItem(for model: TogentModelOption) -> NSMenuItem {
        let item = NSMenuItem(
            title: model.displayName,
            action: nil,
            keyEquivalent: ""
        )
        item.representedObject = model.publishedModelID
        item.image = NSImage(
            systemSymbolName: model.capabilitySymbolName,
            accessibilityDescription: model.capabilityTitle
        )
        return item
    }

    static func showError(_ error: Error, title: String = "Togent 设置未保存") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    fileprivate static func label(_ title: String, y: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.frame = NSRect(x: 0, y: y, width: 94, height: 20)
        return label
    }
}

struct TogentRolePathBinding {
    private let parentPath: String
    private(set) var isAutomatic: Bool

    init(workspacePath: String, automatic: Bool) {
        parentPath = URL(fileURLWithPath: workspacePath)
            .deletingLastPathComponent()
            .path
        isAutomatic = automatic
    }

    static func isManagedDefaultWorkspace(
        roleName: String,
        workspacePath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard TogentRoleName.isValid(roleName) else { return false }
        let expected = homeDirectory
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("togent", isDirectory: true)
            .appendingPathComponent(roleName, isDirectory: true)
            .standardizedFileURL
            .path
        return URL(fileURLWithPath: workspacePath)
            .standardizedFileURL
            .path == expected
    }

    mutating func workspacePath(afterNameChange name: String) -> String? {
        guard isAutomatic, TogentRoleName.isValid(name) else { return nil }
        return URL(fileURLWithPath: parentPath, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .path
    }

    mutating func detach() {
        isAutomatic = false
    }
}

final class TogentRoleFormFields: NSObject, NSTextFieldDelegate {
    let view: NSView
    private let models: [TogentModelOption]
    private let nameField: NSTextField
    private let pathField: NSTextField
    private let promptView: NSTextView
    private let modelPopup: NSPopUpButton
    private let active: NSButton
    private var chooser: TogentPathChooser!
    private var pathBinding: TogentRolePathBinding
    private var lastValidName: String
    private var isUpdatingField = false

    init(
        draft: TogentRoleDraft,
        models: [TogentModelOption],
        automaticPath: Bool
    ) {
        let width: CGFloat = 560
        view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 330))
        self.models = models
        nameField = NSTextField(string: draft.name)
        pathField = NSTextField(string: draft.workspacePath)
        promptView = NSTextView()
        modelPopup = NSPopUpButton()
        active = NSButton(
            checkboxWithTitle: "设为当前微信角色（同一时间最多一个）",
            target: nil,
            action: nil
        )
        pathBinding = TogentRolePathBinding(
            workspacePath: draft.workspacePath,
            automatic: automaticPath
        )
        lastValidName = draft.name
        super.init()

        nameField.placeholderString = "例如：developer 或 qa-agent"
        nameField.frame = NSRect(x: 104, y: 292, width: width - 108, height: 26)
        nameField.delegate = self
        view.addSubview(TogentPrompts.label("角色名称", y: 296))
        view.addSubview(nameField)

        pathField.placeholderString = "/Users/…/Documents/togent/developer"
        pathField.frame = NSRect(x: 104, y: 246, width: width - 200, height: 26)
        pathField.delegate = self
        view.addSubview(TogentPrompts.label("项目路径", y: 250))
        view.addSubview(pathField)
        let chooseButton = NSButton(
            title: "选择…",
            target: nil,
            action: #selector(TogentPathChooser.chooseDirectory)
        )
        chooseButton.frame = NSRect(x: width - 86, y: 246, width: 82, height: 28)
        chooser = TogentPathChooser(field: pathField) { [weak self] in
            self?.pathBinding.detach()
        }
        chooseButton.target = chooser
        view.addSubview(chooseButton)

        view.addSubview(TogentPrompts.label("角色提示词", y: 211))
        let scroll = NSScrollView(
            frame: NSRect(x: 104, y: 112, width: width - 108, height: 120)
        )
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        promptView.frame = scroll.bounds
        promptView.isRichText = false
        promptView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        scroll.documentView = promptView
        view.addSubview(scroll)

        modelPopup.frame = NSRect(x: 104, y: 66, width: width - 108, height: 28)
        view.addSubview(TogentPrompts.label("模型", y: 72))
        view.addSubview(modelPopup)

        active.frame = NSRect(x: 104, y: 22, width: width - 108, height: 28)
        view.addSubview(active)
        apply(draft: draft, automaticPath: automaticPath)
    }

    var draft: TogentRoleDraft {
        TogentRoleDraft(
            name: nameField.stringValue,
            workspacePath: pathField.stringValue,
            prompt: promptView.string,
            publishedModelID: modelPopup.selectedItem?.representedObject as? String ?? "",
            isActive: active.state == .on
        )
    }

    func apply(draft: TogentRoleDraft, automaticPath: Bool) {
        isUpdatingField = true
        nameField.stringValue = draft.name
        pathField.stringValue = draft.workspacePath
        promptView.string = draft.prompt
        active.state = draft.isActive ? .on : .off
        pathBinding = TogentRolePathBinding(
            workspacePath: draft.workspacePath,
            automatic: automaticPath
        )
        lastValidName = draft.name
        configureModelPopup(selectedID: draft.publishedModelID)
        isUpdatingField = false
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !isUpdatingField, let field = notification.object as? NSTextField else {
            return
        }
        if field === nameField {
            let value = nameField.stringValue
            guard TogentRoleName.isValidPartial(value) else {
                NSSound.beep()
                isUpdatingField = true
                nameField.stringValue = lastValidName
                nameField.currentEditor()?.selectedRange = NSRange(
                    location: lastValidName.utf16.count,
                    length: 0
                )
                isUpdatingField = false
                return
            }
            lastValidName = value
            if let nextPath = pathBinding.workspacePath(afterNameChange: value) {
                isUpdatingField = true
                pathField.stringValue = nextPath
                isUpdatingField = false
            }
            return
        }
        if field === pathField {
            pathBinding.detach()
        }
    }

    private func configureModelPopup(selectedID: String) {
        modelPopup.removeAllItems()
        var found = false
        if selectedID.isEmpty {
            modelPopup.addItem(withTitle: "未配置")
            modelPopup.lastItem?.representedObject = ""
            modelPopup.lastItem?.image = NSImage(
                systemSymbolName: "minus.circle",
                accessibilityDescription: "未配置"
            )
            found = true
        }
        for model in models {
            let item = TogentPrompts.modelMenuItem(for: model)
            modelPopup.menu?.addItem(item)
            if model.publishedModelID == selectedID {
                modelPopup.select(item)
                found = true
            }
        }
        if !selectedID.isEmpty, !found {
            modelPopup.insertItem(withTitle: "已失效 · \(selectedID)", at: 0)
            modelPopup.item(at: 0)?.representedObject = selectedID
            modelPopup.item(at: 0)?.image = NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: "模型已失效"
            )
            modelPopup.selectItem(at: 0)
        }
        modelPopup.isEnabled = !models.isEmpty
    }
}

final class TogentRoleCopySourceController: NSObject {
    private let options: [TogentRoleCopyOption]
    private weak var fields: TogentRoleFormFields?

    init(
        popup: NSPopUpButton,
        options: [TogentRoleCopyOption],
        fields: TogentRoleFormFields
    ) {
        self.options = options
        self.fields = fields
        super.init()
        popup.selectItem(at: 0)
    }

    @objc func sourceChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard options.indices.contains(index) else { return }
        fields?.apply(draft: options[index].draft, automaticPath: true)
    }
}

private final class TogentPathChooser: NSObject {
    private weak var field: NSTextField?
    private let onSelection: () -> Void

    init(field: NSTextField, onSelection: @escaping () -> Void = {}) {
        self.field = field
        self.onSelection = onSelection
    }

    @objc func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择 Togent 角色项目目录"
        if let raw = field?.stringValue, !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            panel.directoryURL = FileManager.default.fileExists(atPath: url.path)
                ? url
                : url.deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            field?.stringValue = url.path
            onSelection()
        }
    }
}
