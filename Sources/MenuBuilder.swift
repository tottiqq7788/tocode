import AppKit

/// 目录树菜单构建器：把目录内容渲染为 NSMenu 树，子文件夹惰性递归展开。
/// 每个条目与底部动作都带原生 alternate 项：菜单打开期间按住 Command 时，
/// 「新增」自动变为「清空」，条目点击从复制路径切换为删除；松开即恢复。
@MainActor
final class MenuBuilder: NSObject, NSMenuDelegate {
    private let fs = FileSystemService()
    private let clipboard = ClipboardService()
    private var menuDirectoryMap: [ObjectIdentifier: String] = [:]
    private var includeHidden = true

    private static let placeholderTitle = "\u{2026}"
    private static let newTitle = "新增"
    private static let clearTitle = "清空"

    /// 立即填充根菜单（根目录内容在弹出前就绪）。子菜单沿用同一显示状态。
    func fillRoot(_ menu: NSMenu, with directory: String, includeHidden: Bool = true) {
        self.includeHidden = includeHidden
        fill(menu, with: directory)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let dir = menuDirectoryMap[ObjectIdentifier(menu)] else { return }
        // 首次展开：移除占位项，填充真实子项
        guard let idx = menu.items.firstIndex(where: { $0.title == Self.placeholderTitle }) else { return }
        menu.removeItem(at: idx)
        fill(menu, with: dir)
    }

    private func fill(_ menu: NSMenu, with dir: String) {
        let entries = fs.entries(in: dir, includeHidden: includeHidden)
        if entries.isEmpty {
            let empty = NSMenuItem(title: "（空）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for entry in entries {
                addEntryItems(for: entry, to: menu)
            }
        }
        menu.addItem(.separator())
        addBottomActionItems(for: dir, to: menu)
    }

    /// 每个条目添加「复制路径」主项 + Command 下的「删除」alternate 项。
    private func addEntryItems(for entry: FileSystemService.Entry, to menu: NSMenu) {
        let primary = NSMenuItem(title: entry.name, action: #selector(copyItem(_:)), keyEquivalent: "")
        primary.target = self
        primary.representedObject = entry.path

        if entry.kind == .directory {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            submenu.delegate = self

            let placeholder = NSMenuItem(title: Self.placeholderTitle, action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)

            menuDirectoryMap[ObjectIdentifier(submenu)] = entry.path
            primary.submenu = submenu
        }

        let alternate = NSMenuItem(title: entry.name, action: #selector(deleteItem(_:)), keyEquivalent: "")
        alternate.target = self
        alternate.representedObject = entry.path
        alternate.isAlternate = true
        alternate.keyEquivalentModifierMask = [.command]

        menu.addItem(primary)
        menu.addItem(alternate)
    }

    /// 底部动作：普通「新增」主项 + Command 下的「清空」alternate 项。
    private func addBottomActionItems(for directory: String, to menu: NSMenu) {
        let primary = NSMenuItem(title: Self.newTitle, action: #selector(newItem(_:)), keyEquivalent: "")
        primary.target = self
        primary.representedObject = directory
        primary.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新增")

        let alternate = NSMenuItem(title: Self.clearTitle, action: #selector(clearDirectory(_:)), keyEquivalent: "")
        alternate.target = self
        alternate.representedObject = directory
        alternate.isAlternate = true
        alternate.keyEquivalentModifierMask = [.command]
        alternate.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "清空")

        menu.addItem(primary)
        menu.addItem(alternate)
    }

    // MARK: - 普通模式

    @objc private func copyItem(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String {
            clipboard.copyPath(path)
        }
    }

    // MARK: - 新增

    @objc private func newItem(_ sender: NSMenuItem) {
        guard let directory = sender.representedObject as? String else { return }
        guard let input = NewFilePrompt.prompt(in: directory) else { return }
        do {
            _ = try fs.createFile(in: directory, name: input.name, format: input.format)
        } catch {
            presentError(error, title: "新增失败")
        }
    }

    // MARK: - 删除模式

    @objc private func deleteItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let name = (path as NSString).lastPathComponent
        guard DestructionConfirmation.confirm(
            title: "删除「\(name)」？",
            message: "将把「\(name)」移入废纸篓。此操作可恢复。"
        ) else { return }
        do {
            try fs.trashItem(at: path)
        } catch {
            presentError(error, title: "删除失败")
        }
    }

    @objc private func clearDirectory(_ sender: NSMenuItem) {
        guard let directory = sender.representedObject as? String else { return }
        let name = (directory as NSString).lastPathComponent
        guard DestructionConfirmation.confirm(
            title: "清空「\(name)」？",
            message: "将把「\(name)」内的全部内容移入废纸篓。此操作可恢复。"
        ) else { return }
        do {
            try fs.trashContents(of: directory)
        } catch {
            presentError(error, title: "清空失败")
        }
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

/// 新增文件小窗口：输入文件名并选择常见格式。
@MainActor
enum NewFilePrompt {
    static func prompt(in directory: String) -> (name: String, format: FileFormat)? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "新增文件"
        alert.informativeText = "在「\((directory as NSString).lastPathComponent)」中新建一个空文件。"
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        nameField.placeholderString = "文件名（可省略扩展名）"

        let formatPopUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24), pullsDown: false)
        for format in FileFormat.allCases {
            formatPopUp.addItem(withTitle: "\(format.displayName)（.\(format.fileExtension)）")
            formatPopUp.lastItem?.representedObject = format.rawValue
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let nameLabel = NSTextField(labelWithString: "文件名")
        let formatLabel = NSTextField(labelWithString: "格式")
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        formatLabel.translatesAutoresizingMaskIntoConstraints = false
        nameField.translatesAutoresizingMaskIntoConstraints = false
        formatPopUp.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(nameLabel)
        stack.addArrangedSubview(nameField)
        stack.addArrangedSubview(formatLabel)
        stack.addArrangedSubview(formatPopUp)
        NSLayoutConstraint.activate([
            nameField.widthAnchor.constraint(equalToConstant: 260),
            formatPopUp.widthAnchor.constraint(equalToConstant: 260)
        ])
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 110)

        alert.accessoryView = stack
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let selected = formatPopUp.selectedItem?.representedObject as? String
        let format = selected.flatMap { FileFormat(rawValue: $0) } ?? .txt
        return (nameField.stringValue, format)
    }
}

/// 删除/清空前的确认窗口。
@MainActor
enum DestructionConfirmation {
    static func confirm(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
