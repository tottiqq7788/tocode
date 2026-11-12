import AppKit

/// 状态栏菜单跟踪不会给「有下级菜单」的条目发送 action。
/// 这类点击要由我们执行动作并关闭菜单；Shift 多选仍只保持菜单打开。
enum DirectoryTrackedClick: Equatable {
    case passThrough
    case keepMenuOpen
    case performActionAndClose
}

enum DirectoryTrackedClickPolicy {
    static func decide(
        mode: DirectoryMenuMode,
        shiftHeld: Bool,
        entryPath: String?,
        itemHasSubmenu: Bool,
        itemHasAction: Bool,
        sessionPaths: inout [String]
    ) -> DirectoryTrackedClick {
        if DirectoryMenuMultiCopy.handleClick(
            mode: mode,
            shiftHeld: shiftHeld,
            entryPath: entryPath,
            sessionPaths: &sessionPaths
        ) {
            return .keepMenuOpen
        }
        if itemHasSubmenu && itemHasAction {
            return .performActionAndClose
        }
        return .passThrough
    }
}

/// 同一次点击可能被手动发送一次、系统再投递一次。第二次丢掉。
struct MenuActionGate {
    private(set) var armed: ObjectIdentifier?
    private var ran = false

    mutating func arm(_ item: ObjectIdentifier) {
        armed = item
        ran = false
    }

    mutating func accept(_ item: ObjectIdentifier) -> Bool {
        guard armed == item else { return true }
        if ran { return false }
        ran = true
        return true
    }

    mutating func disarm(ifArmed item: ObjectIdentifier) {
        guard armed == item else { return }
        armed = nil
        ran = false
    }
}

/// 下级菜单打开后约 40 毫秒，系统会在光标没动时送一次鼠标离开。
/// 只丢掉这一次：仍在菜单窗口内、位移为 0、位置与打开时相同、且发生在打开后 80 毫秒内。
struct SpuriousMenuExit {
    private(set) var openedAt: Date?
    private(set) var openedMouse: CGPoint?

    mutating func noteOpen(mouse: CGPoint, at: Date) {
        openedAt = at
        openedMouse = mouse
    }

    mutating func reset() {
        openedAt = nil
        openedMouse = nil
    }

    func shouldSwallow(
        deltaX: CGFloat,
        deltaY: CGFloat,
        mouse: CGPoint,
        at: Date,
        pointerInsideMenu: Bool
    ) -> Bool {
        guard pointerInsideMenu else { return false }
        guard abs(deltaX) < 0.5, abs(deltaY) < 0.5 else { return false }
        guard let openedAt, let openedMouse else { return false }
        let age = at.timeIntervalSince(openedAt)
        guard age >= 0, age < 0.08 else { return false }
        guard abs(mouse.x - openedMouse.x) < 1.5, abs(mouse.y - openedMouse.y) < 1.5 else { return false }
        return true
    }
}

@MainActor
enum SpuriousMenuExitHub {
    private static var state = SpuriousMenuExit()

    static func reset() {
        state.reset()
    }

    static func note(mouse: CGPoint, at: Date = Date()) {
        state.noteOpen(mouse: mouse, at: at)
    }

    static func shouldSwallow(
        deltaX: CGFloat,
        deltaY: CGFloat,
        mouse: CGPoint,
        at: Date = Date(),
        pointerInsideMenu: Bool
    ) -> Bool {
        state.shouldSwallow(
            deltaX: deltaX,
            deltaY: deltaY,
            mouse: mouse,
            at: at,
            pointerInsideMenu: pointerInsideMenu
        )
    }

    static func pointerInsideOwnMenu(_ mouse: CGPoint) -> Bool {
        let screenMax = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for dict in info {
            guard (dict[kCGWindowOwnerPID as String] as? Int) == Int(pid) else { continue }
            guard let bounds = dict[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0
            guard width >= 18, height >= 18, height <= 900, width <= 1400 else { continue }
            let cg = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: width, height: height)
            let frame = CGRect(x: cg.minX, y: screenMax - cg.maxY, width: width, height: height)
            if frame.contains(mouse) { return true }
        }
        return false
    }
}

enum RootConfigMenu {
    static let title = "配置"
    static let copyTitle = "复制路径"
    static let actionTitles = ["读取剪贴板", "更改目录", "重置初始目录"]
    static let followTitles = ["访达跟随", "终端跟随", "codex跟随", "hermes跟随"]
    static var itemTitles: [String] { [copyTitle] + actionTitles + followTitles }
}

/// 目录树菜单构建器：把目录内容渲染为 NSMenu 树，子文件夹惰性递归展开。
/// 根菜单在「新增」上方依次提供「历史」「配置」与「终端」；普通模式点击复制；Shift 多选；Option 删除；Command 访问。
@MainActor
final class MenuBuilder: NSObject, NSMenuDelegate, MenuTrackingForwarding {
    private let fs = FileSystemService()
    private let clipboard = ClipboardService()
    private let opener: WorkspaceItemOpening
    private let resumeStore: DirectoryMenuResumeStore
    private let terminal: DirectoryTerminalLaunching
    private let terminalWindows: DirectoryTerminalWindowStore
    private var menuDirectoryMap: [ObjectIdentifier: String] = [:]
    private var includeHidden = true
    private var mode: DirectoryMenuMode = .normal
    private var treeRoot: String = RootPathStore.documentsDirectory()

    private var entryItems: [EntryItem] = []
    private var bottomItems: [BottomItem] = []
    /// 仅根菜单：在「历史」与「终端」之间插入「配置」夹。
    var makeRootConfigItem: (() -> NSMenuItem)?

    private var multiCopyPaths: [String] = []
    private var actionGate = MenuActionGate()
    private var shiftClickMonitor: Any?
    private weak var trackingRootMenu: NSMenu?
    private var needsSameMenuRepop = false
    weak var menuTrackingSink: MenuTrackingSinking?

    private static let placeholderTitle = "\u{2026}"
    private static let newTitle = "新增"
    private static let clearTitle = "清空"
    private static let accessTitle = "访问"
    private static let historyTitle = "历史"
    private static let terminalTitle = "终端"

    init(
        opener: WorkspaceItemOpening = NSWorkspaceItemOpener(),
        resumeStore: DirectoryMenuResumeStore = DirectoryMenuResumeStore(),
        terminal: DirectoryTerminalLaunching = SystemDirectoryTerminalLauncher(),
        terminalWindows: DirectoryTerminalWindowStore = DirectoryTerminalWindowStore()
    ) {
        self.opener = opener
        self.resumeStore = resumeStore
        self.terminal = terminal
        self.terminalWindows = terminalWindows
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

    /// 立即填充根菜单（始终为当前树根第一层）；子菜单沿用同一显示状态。
    func fillRoot(_ menu: NSMenu, with directory: String, includeHidden: Bool = true) {
        self.includeHidden = includeHidden
        self.mode = .normal
        self.treeRoot = DirectoryMenuResume.standardize(directory)
        entryItems.removeAll()
        bottomItems.removeAll()
        menuDirectoryMap.removeAll()
        menu.delegate = self
        fill(menu, with: self.treeRoot, showHistory: true)
    }

    /// 子菜单窗口出现前填充。跟踪开始后再改条目数会让子菜单被关掉，鼠标不动也不会再展开。
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        menuTrackingSink?.menuTrackingHighlight(menu, item: item)
        guard let submenu = item?.submenu else { return }
        let before = submenu.items.count
        populateIfNeeded(submenu)
        if submenu.items.count != before {
            menuTrackingSink?.menuTrackingItemCountChanged(submenu, before: before, after: submenu.items.count)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        let before = menu.items.count
        populateIfNeeded(menu)
        if menu.items.count != before {
            menuTrackingSink?.menuTrackingItemCountChanged(menu, before: before, after: menu.items.count)
        }
        menuTrackingSink?.menuTrackingWillOpen(menu)
        if menu.supermenu != nil {
            SpuriousMenuExitHub.note(mouse: NSEvent.mouseLocation)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTrackingSink?.menuTrackingDidClose(menu)
    }

    /// 只在仍是单个占位项时填充一次。高亮和打开都可能走到这里，不能重复追加。
    private func populateIfNeeded(_ menu: NSMenu) {
        guard let dir = menuDirectoryMap[ObjectIdentifier(menu)] else { return }
        guard menu.items.count == 1, menu.items[0].title == Self.placeholderTitle else { return }
        menu.removeItem(at: 0)
        fill(menu, with: dir, showHistory: false)
    }

    func setMode(_ mode: DirectoryMenuMode) {
        guard mode != self.mode else { return }
        self.mode = mode

        for wrapper in entryItems {
            guard let item = wrapper.item else { continue }
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

    private func fill(_ menu: NSMenu, with dir: String, showHistory: Bool) {
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
        if showHistory {
            menu.addItem(makeHistoryItem())
            if let makeRootConfigItem {
                menu.addItem(makeRootConfigItem())
            }
            menu.addItem(makeTerminalItem(for: dir))
        }
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

    private func makeHistoryItem() -> NSMenuItem {
        let item = NSMenuItem(title: Self.historyTitle, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "clock", accessibilityDescription: Self.historyTitle)
        item.isAlternate = false

        let sibling = DirectoryMenuResume.siblingDirectory(
            lastClicked: resumeStore.load(),
            root: treeRoot,
            isDirectory: { fs.isExistingDirectory($0) }
        )
        guard let sibling else {
            item.isEnabled = false
            return item
        }

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.delegate = self
        let placeholder = NSMenuItem(title: Self.placeholderTitle, action: nil, keyEquivalent: "")
        placeholder.isEnabled = false
        submenu.addItem(placeholder)
        menuDirectoryMap[ObjectIdentifier(submenu)] = sibling
        item.submenu = submenu
        return item
    }

    private func makeTerminalItem(for directory: String) -> NSMenuItem {
        let item = NSMenuItem(title: Self.terminalTitle, action: #selector(openTerminal(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = directory
        item.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: Self.terminalTitle)
        item.isAlternate = false
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

    private func rememberClick(_ path: String) {
        resumeStore.save(path)
    }

    // MARK: - 普通模式

    @objc private func copyItem(_ sender: NSMenuItem) {
        guard actionGate.accept(ObjectIdentifier(sender)) else { return }
        guard let path = sender.representedObject as? String else { return }
        if mode == .normal, NSEvent.modifierFlags.contains(.shift) {
            if multiCopyPaths.last != path {
                multiCopyPaths.append(path)
            }
            rememberClick(path)
            clipboard.copyPaths(multiCopyPaths)
            needsSameMenuRepop = true
            return
        }
        multiCopyPaths = []
        rememberClick(path)
        clipboard.copyPath(path)
    }

    private func handlePotentialShiftMultiCopy(_ event: NSEvent) -> NSEvent? {
        guard let root = trackingRootMenu else { return event }
        let item = highlightedEntryItem(in: root)
        let entryPath = item?.representedObject as? String
        let decision = DirectoryTrackedClickPolicy.decide(
            mode: mode,
            shiftHeld: NSEvent.modifierFlags.contains(.shift),
            entryPath: entryPath,
            itemHasSubmenu: item?.submenu != nil,
            itemHasAction: item?.action != nil,
            sessionPaths: &multiCopyPaths
        )
        switch decision {
        case .passThrough:
            return event
        case .keepMenuOpen:
            if let entryPath {
                rememberClick(entryPath)
            }
            clipboard.copyPaths(multiCopyPaths)
            return nil
        case .performActionAndClose:
            guard let item else { return event }
            performSubmenuItemClick(item)
            return nil
        }
    }

    /// 状态栏跟踪里，带下级菜单的条目收不到 action。这里补上一次，并避免系统再投递时执行第二遍。
    private func performSubmenuItemClick(_ item: NSMenuItem) {
        guard let action = item.action else { return }
        let identity = ObjectIdentifier(item)
        actionGate.arm(identity)
        NSApp.sendAction(action, to: item.target, from: item)
        trackingRootMenu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            self?.actionGate.disarm(ifArmed: identity)
        }
    }

    private func highlightedEntryItem(in menu: NSMenu) -> NSMenuItem? {
        guard let item = menu.highlightedItem else { return nil }
        if let submenu = item.submenu, let nested = highlightedEntryItem(in: submenu) {
            return nested
        }
        guard entryItems.contains(where: { $0.item === item }) else { return nil }
        return item
    }

    @objc private func openTerminal(_ sender: NSMenuItem) {
        guard let directory = sender.representedObject as? String else { return }
        do {
            let binding = try terminal.openTerminal(at: directory)
            terminalWindows.remember(binding)
        } catch {
            presentError(error, title: "打开终端失败")
        }
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
            rememberClick(createdPath)
            clipboard.copyPath(createdPath)
        } catch {
            presentError(error, title: "新增失败")
        }
    }

    // MARK: - 访问模式

    @objc private func accessEntry(_ sender: NSMenuItem) {
        guard actionGate.accept(ObjectIdentifier(sender)) else { return }
        guard let path = sender.representedObject as? String,
              let kind = entryItems.first(where: { $0.path == path })?.kind else { return }
        rememberClick(path)
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
        guard actionGate.accept(ObjectIdentifier(sender)) else { return }
        guard let path = sender.representedObject as? String else { return }
        let name = (path as NSString).lastPathComponent
        guard DestructionConfirmation.confirm(
            title: "删除「\(name)」？",
            message: "将把「\(name)」移入废纸篓。此操作可恢复。"
        ) else { return }
        do {
            try fs.trashItem(at: path)
            rememberClick(path)
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
        withExtendedLifetime(updater) {}
        alert.accessoryView = stack

        guard alert.runModalFocusingFirstTextField() == .alertFirstButtonReturn else { return nil }
        let kind: Kind = typeControl.selectedSegment == 1 ? .file : .folder
        let selected = formatPopUp.selectedItem?.representedObject as? String
        let format = selected.flatMap { FileFormat(rawValue: $0) } ?? .txt
        return Input(kind: kind, name: nameField.stringValue, format: format)
    }
}

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
