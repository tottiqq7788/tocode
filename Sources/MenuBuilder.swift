import AppKit

/// 目录树菜单构建器：把目录内容渲染为 NSMenu 树，子文件夹惰性递归展开。
/// 普通模式点击条目复制路径；按住 Command 进入删除模式，点击条目改为删除，
/// 且每个目录菜单底部的「新增」实时变为「清空」。松开 Command 后恢复。
@MainActor
final class MenuBuilder: NSObject, NSMenuDelegate {
    private let fs = FileSystemService()
    private let clipboard = ClipboardService()
    private var menuDirectoryMap: [ObjectIdentifier: String] = [:]
    private var includeHidden = true
    private var deleteMode = false
    private var managedMenus: [ObjectIdentifier: NSMenu] = [:]
    private var bottomItems: [ObjectIdentifier: NSMenuItem] = [:]
    private var itemSubmenus: [ObjectIdentifier: NSMenu] = [:]

    private static let placeholderTitle = "\u{2026}"
    private static let newTitle = "新增"
    private static let clearTitle = "清空"

    private enum ItemTag {
        static let entry = 1
        static let bottomAction = 2
    }

    enum Mode {
        case copy
        case delete
    }

    /// 立即填充根菜单（根目录内容在弹出前就绪）。子菜单沿用同一显示状态。
    func fillRoot(_ menu: NSMenu, with directory: String, includeHidden: Bool = true, mode: Mode = .copy) {
        self.includeHidden = includeHidden
        self.deleteMode = (mode == .delete)
        managedMenus[ObjectIdentifier(menu)] = menu
        fill(menu, with: directory)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let dir = menuDirectoryMap[ObjectIdentifier(menu)] else { return }
        // 首次展开：移除占位项，填充真实子项
        guard let idx = menu.items.firstIndex(where: { $0.title == Self.placeholderTitle }) else { return }
        menu.removeItem(at: idx)
        fill(menu, with: dir)
    }

    /// 菜单打开期间实时切换普通/删除模式；已打开的菜单与后续展开的子菜单都会跟随。
    func setMode(_ mode: Mode) {
        let isDelete = (mode == .delete)
        guard isDelete != deleteMode else { return }
        deleteMode = isDelete
        for menu in managedMenus.values {
            applyMode(isDelete, to: menu)
        }
    }

    private func fill(_ menu: NSMenu, with dir: String) {
        let entries = fs.entries(in: dir, includeHidden: includeHidden)
        if entries.isEmpty {
            let empty = NSMenuItem(title: "（空）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for entry in entries {
                menu.addItem(makeItem(for: entry))
            }
        }
        menu.addItem(.separator())
        menu.addItem(makeBottomActionItem(for: dir))
    }

    private func makeItem(for entry: FileSystemService.Entry) -> NSMenuItem {
        let action: Selector = deleteMode ? #selector(deleteItem(_:)) : #selector(copyItem(_:))
        let item = NSMenuItem(title: entry.name, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = entry.path
        item.tag = ItemTag.entry

        if entry.kind == .directory {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            submenu.delegate = self

            // 占位（惰性加载子项）；普通模式点击文件夹本身复制路径，
            // 删除模式点击文件夹本身删除该文件夹。
            let placeholder = NSMenuItem(title: Self.placeholderTitle, action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)

            menuDirectoryMap[ObjectIdentifier(submenu)] = entry.path
            managedMenus[ObjectIdentifier(submenu)] = submenu
            itemSubmenus[ObjectIdentifier(item)] = submenu

            // 删除模式下移除子菜单，使点击文件夹能触发删除动作；松开 Command 后恢复。
            item.submenu = deleteMode ? nil : submenu
        }
        return item
    }

    private func makeBottomActionItem(for directory: String) -> NSMenuItem {
        let item = NSMenuItem(
            title: deleteMode ? Self.clearTitle : Self.newTitle,
            action: deleteMode ? #selector(clearDirectory(_:)) : #selector(newItem(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = directory
        item.tag = ItemTag.bottomAction
        item.image = NSImage(
            systemSymbolName: deleteMode ? "trash" : "plus",
            accessibilityDescription: deleteMode ? "清空" : "新增"
        )
        bottomItems[ObjectIdentifier(item)] = item
        return item
    }

    private func applyMode(_ isDelete: Bool, to menu: NSMenu) {
        for item in menu.items {
            switch item.tag {
            case ItemTag.entry:
                item.action = isDelete ? #selector(deleteItem(_:)) : #selector(copyItem(_:))
                if isDelete {
                    if let submenu = item.submenu {
                        itemSubmenus[ObjectIdentifier(item)] = submenu
                        item.submenu = nil
                    }
                } else {
                    if let submenu = itemSubmenus[ObjectIdentifier(item)] {
                        item.submenu = submenu
                        itemSubmenus.removeValue(forKey: ObjectIdentifier(item))
                    }
                }
            case ItemTag.bottomAction:
                item.title = isDelete ? Self.clearTitle : Self.newTitle
                item.action = isDelete ? #selector(clearDirectory(_:)) : #selector(newItem(_:))
                item.image = NSImage(
                    systemSymbolName: isDelete ? "trash" : "plus",
                    accessibilityDescription: isDelete ? "清空" : "新增"
                )
            default:
                break
            }
        }
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
