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

    /// 已渲染、需要在 Command 切换时改动的项（直接保存强引用）。
    private var entryItems: [EntryItem] = []
    private var bottomItems: [BottomItem] = []

    private static let placeholderTitle = "\u{2026}"
    private static let newTitle = "新增"
    private static let clearTitle = "清空"

    private final class EntryItem {
        weak var item: NSMenuItem?
        let path: String
        let submenu: NSMenu?
        init(item: NSMenuItem, path: String, submenu: NSMenu?) {
            self.item = item
            self.path = path
            self.submenu = submenu
        }
    }

    private final class BottomItem {
        weak var item: NSMenuItem?
        let directory: String
        init(item: NSMenuItem, directory: String) {
            self.item = item
            self.directory = directory
        }
    }

    /// 立即填充根菜单（根目录内容在弹出前就绪）。子菜单沿用同一显示状态。
    func fillRoot(_ menu: NSMenu, with directory: String, includeHidden: Bool = true) {
        self.includeHidden = includeHidden
        self.deleteMode = false
        entryItems.removeAll()
        bottomItems.removeAll()
        fill(menu, with: directory)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let dir = menuDirectoryMap[ObjectIdentifier(menu)] else { return }
        // 首次展开：移除占位项，填充真实子项
        guard let idx = menu.items.firstIndex(where: { $0.title == Self.placeholderTitle }) else { return }
        menu.removeItem(at: idx)
        fill(menu, with: dir)
    }

    /// 由外部（Command 轮询）在菜单打开期间实时切换模式。
    func setDeleteMode(_ isDelete: Bool) {
        guard isDelete != deleteMode else { return }
        deleteMode = isDelete

        for wrapper in entryItems {
            guard let item = wrapper.item else { continue }
            if isDelete {
                item.submenu = nil
                item.action = #selector(deleteItem(_:))
                item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除")
            } else {
                item.submenu = wrapper.submenu
                item.action = #selector(copyItem(_:))
                item.image = nil
            }
            notifyChanged(item)
        }

        for wrapper in bottomItems {
            guard let item = wrapper.item else { continue }
            if isDelete {
                item.title = Self.clearTitle
                item.action = #selector(clearDirectory(_:))
                item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "清空")
            } else {
                item.title = Self.newTitle
                item.action = #selector(newItem(_:))
                item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新增")
            }
            notifyChanged(item)
        }
    }

    private func notifyChanged(_ item: NSMenuItem) {
        item.menu?.itemChanged(item)
        item.menu?.update()
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
        let item = NSMenuItem(title: entry.name, action: #selector(copyItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = entry.path

        var submenu: NSMenu? = nil
        if entry.kind == .directory {
            let menu = NSMenu()
            menu.autoenablesItems = false
            menu.delegate = self

            let placeholder = NSMenuItem(title: Self.placeholderTitle, action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)

            menuDirectoryMap[ObjectIdentifier(menu)] = entry.path
            submenu = menu
            item.submenu = menu
        }

        entryItems.append(EntryItem(item: item, path: entry.path, submenu: submenu))
        return item
    }

    private func makeBottomActionItem(for directory: String) -> NSMenuItem {
        let item = NSMenuItem(title: Self.newTitle, action: #selector(newItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = directory
        item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新增")
        bottomItems.append(BottomItem(item: item, directory: directory))
        return item
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
