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
    static func roleForm(
        draft: TogentRoleDraft,
        models: [TogentModelOption],
        isEditing: Bool
    ) -> TogentRolePromptResult {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = isEditing ? "编辑 Togent 角色" : "新增 Togent 角色"
        alert.informativeText = models.isEmpty
            ? "当前没有健康的模型中转可供选择。请先配置“模型 → 厂家”。"
            : "微信普通消息只会发送给当前勾选的一个角色。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        if isEditing {
            alert.addButton(withTitle: "打开文件位置")
        }

        let width: CGFloat = 560
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 330))
        let nameField = NSTextField(string: draft.name)
        nameField.placeholderString = "例如：开发助手"
        addRow(
            title: "角色名称",
            control: nameField,
            y: 292,
            width: width,
            to: view
        )

        let pathField = NSTextField(string: draft.workspacePath)
        pathField.placeholderString = "/Users/…/Documents/togent/角色1"
        pathField.frame = NSRect(x: 104, y: 246, width: width - 200, height: 26)
        view.addSubview(label("项目路径", y: 250))
        view.addSubview(pathField)
        let chooseButton = NSButton(
            title: "选择…",
            target: nil,
            action: #selector(TogentPathChooser.chooseDirectory)
        )
        chooseButton.frame = NSRect(x: width - 86, y: 246, width: 82, height: 28)
        let chooser = TogentPathChooser(field: pathField)
        chooseButton.target = chooser
        view.addSubview(chooseButton)

        let promptLabel = label("角色提示词", y: 211)
        view.addSubview(promptLabel)
        let scroll = NSScrollView(frame: NSRect(x: 104, y: 112, width: width - 108, height: 120))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let promptView = NSTextView(frame: scroll.bounds)
        promptView.isRichText = false
        promptView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        promptView.string = draft.prompt
        scroll.documentView = promptView
        view.addSubview(scroll)

        let modelPopup = NSPopUpButton(
            frame: NSRect(x: 104, y: 66, width: width - 108, height: 28),
            pullsDown: false
        )
        var hasCurrentModel = false
        if draft.publishedModelID.isEmpty {
            modelPopup.addItem(withTitle: "未配置")
            modelPopup.lastItem?.representedObject = ""
            modelPopup.select(modelPopup.lastItem)
            hasCurrentModel = true
        }
        for model in models {
            modelPopup.addItem(withTitle: model.displayName)
            modelPopup.lastItem?.representedObject = model.publishedModelID
            if model.publishedModelID == draft.publishedModelID {
                modelPopup.select(modelPopup.lastItem)
                hasCurrentModel = true
            }
        }
        if !draft.publishedModelID.isEmpty, !hasCurrentModel {
            modelPopup.insertItem(
                withTitle: "已失效 · \(draft.publishedModelID)",
                at: 0
            )
            modelPopup.item(at: 0)?.representedObject = draft.publishedModelID
            modelPopup.selectItem(at: 0)
        }
        modelPopup.isEnabled = !models.isEmpty
        view.addSubview(label("模型", y: 72))
        view.addSubview(modelPopup)

        let active = NSButton(
            checkboxWithTitle: "设为当前微信角色（同一时间最多一个）",
            target: nil,
            action: nil
        )
        active.state = draft.isActive ? .on : .off
        active.frame = NSRect(x: 104, y: 22, width: width - 108, height: 28)
        view.addSubview(active)

        alert.accessoryView = view
        alert.buttons.first?.isEnabled = !models.isEmpty
            || (isEditing && draft.publishedModelID.isEmpty)
        let response = withExtendedLifetime(chooser) {
            alert.runModalFocusingFirstTextField()
        }
        guard response == .alertFirstButtonReturn
                || response == .alertThirdButtonReturn else {
            return .cancel
        }
        let selectedModel = modelPopup.selectedItem?.representedObject as? String ?? ""
        let candidate = TogentRoleDraft(
            name: nameField.stringValue,
            workspacePath: pathField.stringValue,
            prompt: promptView.string,
            publishedModelID: selectedModel,
            isActive: active.state == .on
        )
        if response == .alertThirdButtonReturn {
            return .openWorkspace(candidate)
        }
        return .save(candidate)
    }

    static func showError(_ error: Error, title: String = "Togent 设置未保存") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private static func addRow(
        title: String,
        control: NSView,
        y: CGFloat,
        width: CGFloat,
        to view: NSView
    ) {
        view.addSubview(label(title, y: y + 4))
        control.frame = NSRect(x: 104, y: y, width: width - 108, height: 26)
        view.addSubview(control)
    }

    private static func label(_ title: String, y: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.frame = NSRect(x: 0, y: y, width: 94, height: 20)
        return label
    }
}

private final class TogentPathChooser: NSObject {
    private weak var field: NSTextField?

    init(field: NSTextField) {
        self.field = field
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
        }
    }
}
