import AppKit

/// 目录树菜单构建器：把目录内容渲染为 NSMenu 树，子文件夹惰性递归展开。
/// 记住上次展开文件夹并在下次打开时恢复；普通模式点击复制路径；Shift 多选；Option 删除；Command 访问。
@MainActor
final class MenuBuilder: NSObject, NSMenuDelegate {
    private let fs = FileSystemService()
    private let clipboard = ClipboardService()
    private let opener: WorkspaceItemOpening
    private let resumeStore: DirectoryMenuResumeStore
    private var menuDirectoryMap: [ObjectIdentifier: String] = [:]
    private var includeHidden = true
    private var mode: DirectoryMenuMode = .normal
    /// 当前左键树的权威根（手动根或 Codex 同步根）。
    private var treeRoot: String = RootPathStore.defaultRoot
    /// 本次弹出实际展示的目录（可能是恢复位置）。
    private var displayDirectory: String = RootPathStore.defaultRoot

    /// 已渲染、需要在修饰键切换时改动的项（直接保存强引用）。
    private var entryItems: [EntryItem] = []
    private var bottomItems: [BottomItem] = []

    /// 本次目录树弹出期间累积的 Shift 多选路径。
    private var multiCopyPaths: [String] = []
    private var shiftClickMonitor: Any?
    private weak var trackingRootMenu: NSMenu?
    /// Shift 多选回退：同一菜单再弹一次。
    private var needsSameMenuRepop = false
    /// 上一级/根目录：重建菜单再弹。
    private var needsRebuildRepop = false

    private static let placeholderTitle = "\u{2026}"
    private static let newTitle = "新增"
    private static let clearTitle = "清空"
    private static let accessTitle = "访问"
    private static let parentTitle = "上一级"
    private static let rootTitle = "根目录"

    init(
        opener: WorkspaceItemOpening = NSWorkspaceItemOpener(),
        resumeStore: DirectoryMenuResumeStore = DirectoryMenuResumeStore()
    ) {
        self.opener = opener
        self.resumeStore = resumeStore
        super.init()
    }

    func resetMultiCopySession() {
        multiCopyPaths = []
        needsSameMenuRepop = false
    }

    func consumeSameMenuRepopRequest() -> Bool {
        let value = needsSameMenuRepop
        needsSameMenuRepop = false
        return value
    }

    func consumeRebuildRepopRequest() -> Bool {
        let value = needsRebuildRepop
        needsRebuildRepop = false
        return value
    }

    /// 目录树弹出期间安装 Shift 多选监视器；关闭后由 `endTracking` 拆除。
    /// 不重置多选会话，以便菜单被关闭后立刻再弹出时继续累积。
    func beginTracking(rootMenu: NSMenu) {
        endTracking()
        trackingRootMenu = rootMenu
        shiftClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return event }
            return self.handlePotentialShiftMultiCopy(event)
        }
    }

    func endTracking() {
        if let shiftClickMonitor {
            NSEvent.removeMonitor(shiftClickMonitor)
        }
        shiftClickMonitor = nil
        trackingRootMenu = nil
    }

    private final class EntryItem {
        weak var item: NSMenuItem?
        let path: String
        let kind: FileSystemService.Kind
        let submenu: NSMenu?
        init(item: NSMenuItem, path: String, kind: FileSystemService.Kind, submenu: NSMenu?) {
            self.item = item
            self.path = path
            self.kind = kind
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

    /// 按记忆位置解析本次应展示的目录，并写入当前树根。
    func resolveDisplayDirectory(treeRoot: String) -> String {
        self.treeRoot = DirectoryMenuResume.standardize(treeRoot)
        let display = DirectoryMenuResume.resolveDisplayDirectory(
            saved: resumeStore.load(),
            root: self.treeRoot,
            isDirectory: { self.fs.isExistingDirectory($0) }
        )
        self.displayDirectory = display
        resumeStore.save(display)
        return display
    }

    /// 立即填充展示目录内容。非根层时在顶部加入面包屑与导航项。
    func fillRoot(_ menu: NSMenu, with directory: String, treeRoot: String, includeHidden: Bool = true) {
        self.includeHidden = includeHidden
        self.mode = .normal
        self.treeRoot = DirectoryMenuResume.standardize(treeRoot)
        self.displayDirectory = DirectoryMenuResume.standardize(directory)
        entryItems.removeAll()
        bottomItems.removeAll()
        menuDirectoryMap.removeAll()

        if self.displayDirectory != self.treeRoot {
            insertResumeChrome(into: menu)
        }
        fill(menu, with: self.displayDirectory)
        resumeStore.save(self.displayDirectory)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard let dir = menuDirectoryMap[ObjectIdentifier(menu)] else { return }
        resumeStore.save(dir)
        // 首次展开：移除占位项，填充真实子项
        guard let idx = menu.items.firstIndex(where: { $0.title == Self.placeholderTitle }) else { return }
        menu.removeItem(at: idx)
        fill(menu, with: dir)
    }

    /// 由外部（修饰键轮询）在菜单打开期间实时切换模式。
    func setMode(_ mode: DirectoryMenuMode) {
        guard mode != self.mode else { return }
        self.mode = mode

        for wrapper in entryItems {
            guard let item = wrapper.item else { continue }
            // 保留子菜单：悬停仍可进入下层菜单（下层菜单会在填充时读取当前模式）。
            item.action = entrySelector(for: wrapper.kind)
            item.isAlternate = false
            notifyChanged(item)
        }

        for wrapper in bottomItems {
            guard let item = wrapper.item else { continue }
            applyBottomAppearance(item)
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
        let item = NSMenuItem(title: entry.name, action: entrySelector(for: entry.kind), keyEquivalent: "")
        item.target = self
        item.representedObject = entry.path
        item.isAlternate = false

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

        entryItems.append(EntryItem(item: item, path: entry.path, kind: entry.kind, submenu: submenu))
        return item
    }

    private func makeBottomActionItem(for directory: String) -> NSMenuItem {
        let item = NSMenuItem(title: Self.newTitle, action: #selector(newItem(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = directory
        item.isAlternate = false
        applyBottomAppearance(item)
        bottomItems.append(BottomItem(item: item, directory: directory))
        return item
    }

    private func entrySelector(for kind: FileSystemService.Kind) -> Selector {
        switch mode.action(for: kind) {
        case .copy:
            return #selector(copyItem(_:))
        case .delete:
            return #selector(deleteItem(_:))
        case .openDirectory, .openFile:
            return #selector(accessEntry(_:))
        }
    }

    private func applyBottomAppearance(_ item: NSMenuItem) {
        switch mode.bottomAction() {
        case .create:
            item.title = Self.newTitle
            item.action = #selector(newItem(_:))
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新增")
        case .clear:
            item.title = Self.clearTitle
            item.action = #selector(clearDirectory(_:))
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "清空")
        case .access:
            item.title = Self.accessTitle
            item.action = #selector(accessDirectory(_:))
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "访问")
        }
        item.isAlternate = false
    }

    // MARK: - 普通模式

    @objc private func copyItem(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        // 监视器已处理时通常不会走到这里；若 Shift 点击仍触发了 action，作回退累积并请求再弹出。
        if mode == .normal, NSEvent.modifierFlags.contains(.shift) {
            if multiCopyPaths.last != path {
                multiCopyPaths.append(path)
            }
            clipboard.copyPaths(multiCopyPaths)
            needsSameMenuRepop = true
            return
        }
        multiCopyPaths = []
        clipboard.copyPath(path)
    }

    private func insertResumeChrome(into menu: NSMenu) {
        let crumb = NSMenuItem(
            title: DirectoryMenuResume.breadcrumb(from: treeRoot, to: displayDirectory),
            action: nil,
            keyEquivalent: ""
        )
        crumb.isEnabled = false

        let parent = NSMenuItem(
            title: Self.parentTitle,
            action: #selector(goToParentDirectory(_:)),
            keyEquivalent: ""
        )
        parent.target = self
        parent.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: Self.parentTitle)

        let root = NSMenuItem(
            title: Self.rootTitle,
            action: #selector(goToTreeRoot(_:)),
            keyEquivalent: ""
        )
        root.target = self
        root.image = NSImage(systemSymbolName: "house", accessibilityDescription: Self.rootTitle)

        menu.addItem(crumb)
        menu.addItem(parent)
        menu.addItem(root)
        menu.addItem(.separator())
    }

    @objc private func goToParentDirectory(_ sender: NSMenuItem) {
        let parent = DirectoryMenuResume.parentDirectory(of: displayDirectory)
        let next = DirectoryMenuResume.resolveDisplayDirectory(
            saved: parent,
            root: treeRoot,
            isDirectory: { fs.isExistingDirectory($0) }
        )
        resumeStore.save(next)
        needsRebuildRepop = true
        sender.menu?.cancelTracking()
    }

    @objc private func goToTreeRoot(_ sender: NSMenuItem) {
        resumeStore.save(treeRoot)
        needsRebuildRepop = true
        sender.menu?.cancelTracking()
    }

    /// Shift+普通模式点击条目：追加路径、写剪贴板并吞掉事件以保持菜单打开。
    private func handlePotentialShiftMultiCopy(_ event: NSEvent) -> NSEvent? {
        guard let root = trackingRootMenu else { return event }
        let entryPath = highlightedEntryPath(in: root)
        let keepOpen = DirectoryMenuMultiCopy.handleClick(
            mode: mode,
            shiftHeld: NSEvent.modifierFlags.contains(.shift),
            entryPath: entryPath,
            sessionPaths: &multiCopyPaths
        )
        guard keepOpen else { return event }
        clipboard.copyPaths(multiCopyPaths)
        // 已吞掉 mouseUp，菜单应保持打开；不请求再弹出。
        return nil
    }

    /// 从根菜单向下找当前高亮的条目路径（忽略底部「新增/清空/访问」）。
    private func highlightedEntryPath(in menu: NSMenu) -> String? {
        guard let item = menu.highlightedItem else { return nil }
        if let submenu = item.submenu, let nested = highlightedEntryPath(in: submenu) {
            return nested
        }
        guard entryItems.contains(where: { $0.item === item }) else { return nil }
        return item.representedObject as? String
    }

    // MARK: - 新增

    @objc private func newItem(_ sender: NSMenuItem) {
        guard let directory = sender.representedObject as? String else { return }
        guard let input = NewItemPrompt.prompt(in: directory) else { return }
        do {
            let createdPath: String
            switch input.kind {
            case .file:
                createdPath = try fs.createFile(in: directory, name: input.name, format: input.format)
            case .folder:
                createdPath = try fs.createDirectory(in: directory, name: input.name)
            }
            clipboard.copyPath(createdPath)
        } catch {
            presentError(error, title: "新增失败")
        }
    }

    // MARK: - 访问模式

    @objc private func accessEntry(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let kind = entryItems.first(where: { $0.path == path })?.kind else { return }
        do {
            try DirectoryMenuAccess.perform(path: path, kind: kind, opener: opener)
        } catch {
            presentError(error, title: "打开失败")
        }
    }

    @objc private func accessDirectory(_ sender: NSMenuItem) {
        guard let directory = sender.representedObject as? String else { return }
        do {
            try DirectoryMenuAccess.perform(path: directory, kind: .directory, opener: opener)
        } catch {
            presentError(error, title: "打开失败")
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

/// 新增窗口：可选择新增文件夹或新增文件，文件支持选择常见格式。
@MainActor
enum NewItemPrompt {
    enum Kind {
        case file
        case folder
    }

    struct Input {
        let kind: Kind
        let name: String
        let format: FileFormat
    }

    static func prompt(in directory: String) -> Input? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "新增"
        alert.informativeText = "在「\(directory as NSString).lastPathComponent)」中新建文件或文件夹。"
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")

        let typeControl = NSSegmentedControl(
            labels: ["文件夹", "文件"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        typeControl.selectedSegment = 0
        typeControl.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: "名称")
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        nameField.placeholderString = "文件夹名称"

        let formatLabel = NSTextField(labelWithString: "文件格式")
        let formatPopUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24), pullsDown: false)
        for format in FileFormat.allCases {
            formatPopUp.addItem(withTitle: "\(format.displayName)（.\(format.fileExtension)）")
            formatPopUp.lastItem?.representedObject = format.rawValue
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for v in [typeControl, nameLabel, nameField, formatLabel, formatPopUp] {
            v.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(v)
        }
        NSLayoutConstraint.activate([
            typeControl.widthAnchor.constraint(equalToConstant: 260),
            nameField.widthAnchor.constraint(equalToConstant: 260),
            formatPopUp.widthAnchor.constraint(equalToConstant: 260)
        ])
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 158)

        func updateVisibility() {
            let isFile = typeControl.selectedSegment == 1
            nameLabel.stringValue = isFile ? "文件名" : "文件夹名称"
            nameField.placeholderString = isFile ? "文件名（可省略扩展名）" : "文件夹名称"
            formatLabel.isHidden = !isFile
            formatPopUp.isHidden = !isFile
        }
        updateVisibility()

        let updater = TypeVisibilityUpdater(onChange: updateVisibility)
        typeControl.target = updater
        typeControl.action = #selector(TypeVisibilityUpdater.action(_:))
        // 强引用 updater，避免 target 被释放。
        withExtendedLifetime(updater) {}
        alert.accessoryView = stack

        guard alert.runModalFocusingFirstTextField() == .alertFirstButtonReturn else { return nil }
        let kind: Kind = typeControl.selectedSegment == 1 ? .file : .folder
        let selected = formatPopUp.selectedItem?.representedObject as? String
        let format = selected.flatMap { FileFormat(rawValue: $0) } ?? .txt
        return Input(kind: kind, name: nameField.stringValue, format: format)
    }
}

/// NSSegmentedControl 的目标代理：用于切换新增类型时更新字段可见性。
@MainActor
private final class TypeVisibilityUpdater: NSObject {
    private let onChange: () -> Void
    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    @objc func action(_ sender: Any?) {
        onChange()
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
