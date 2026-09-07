import AppKit
import UserNotifications

/// 菜单栏图标控制器：左键弹目录树，右键弹功能菜单。
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let builder = MenuBuilder()
    private let fs = FileSystemService()
    private let clipboard = ClipboardService()
    private let store = RootPathStore()
    private let visibility = FinderVisibilityService()
    private let finderSelection = FinderSelectionService()
    private let shortcuts: GlobalShortcutService
    private let mouseWheel: MouseWheelReverseService
    private let launchAtLogin: LaunchAtLoginControlling
    private let weChat: WeChatAssociationControlling
    private let codex: CodexProjectService
    private let codexSync: CodexSyncSettingsStore

    init(
        shortcuts: GlobalShortcutService,
        mouseWheel: MouseWheelReverseService,
        launchAtLogin: LaunchAtLoginControlling = LaunchAtLoginService(),
        weChat: WeChatAssociationControlling,
        codex: CodexProjectService = CodexProjectService(),
        codexSync: CodexSyncSettingsStore = CodexSyncSettingsStore()
    ) {
        self.shortcuts = shortcuts
        self.mouseWheel = mouseWheel
        self.launchAtLogin = launchAtLogin
        self.weChat = weChat
        self.codex = codex
        self.codexSync = codexSync
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "tocode")
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        requestNotificationAuthorization()
    }

    @objc private func handleClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .rightMouseUp:
            showActionMenu()
        case .leftMouseUp:
            showDirectoryMenu()
        default:
            break
        }
    }

    /// 左键根目录解析：同步开启且 Codex 项目有效时跟随，否则用手动根目录。
    private func resolveDirectoryRoot() -> String {
        if codexSync.syncEnabled, let project = codex.resolveProject() {
            return project.rootPath
        }
        return store.resolveRoot(isDirectory: { fs.isExistingDirectory($0) })
    }

    /// 左键：弹出目录树（路径选择框），不含功能项。
    private func showDirectoryMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let root = resolveDirectoryRoot()
        builder.fillRoot(menu, with: root, includeHidden: visibility.currentShowAllFiles())

        addBottomSpacer(to: menu)

        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    /// 右键：功能菜单。条件显示「访达目录初始化」；「设置」含子项切换隐藏文件。
    private func showActionMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let syncEnabled = codexSync.syncEnabled
        var manualRootItems: [NSMenuItem] = []

        let readClip = menu.addItem(withTitle: "读取剪贴板", action: #selector(readClipboard), keyEquivalent: "")
        readClip.target = self
        readClip.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        manualRootItems.append(readClip)

        let changeDir = menu.addItem(withTitle: "更改目录", action: #selector(chooseRoot), keyEquivalent: "")
        changeDir.target = self
        changeDir.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        manualRootItems.append(changeDir)

        let resetRoot = menu.addItem(withTitle: "重置初始目录", action: #selector(resetRoot), keyEquivalent: "")
        resetRoot.target = self
        resetRoot.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)
        manualRootItems.append(resetRoot)

        if case .success = finderSelection.resolveInitializationDirectory() {
            let initRoot = menu.addItem(withTitle: "访达目录初始化", action: #selector(initRootFromFinder), keyEquivalent: "")
            initRoot.target = self
            initRoot.image = NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: nil)
            manualRootItems.append(initRoot)
        }

        // codex 子菜单：状态展示 + 「同步项目夹」开关。
        let codexItem = menu.addItem(withTitle: "codex", action: nil, keyEquivalent: "")
        codexItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        let codexMenu = NSMenu()
        codexMenu.autoenablesItems = false
        if let project = codex.resolveProject() {
            let nameRow = codexMenu.addItem(withTitle: "项目：\(project.name)", action: nil, keyEquivalent: "")
            nameRow.isEnabled = false
            let rootRow = codexMenu.addItem(withTitle: project.rootPath, action: nil, keyEquivalent: "")
            rootRow.isEnabled = false
        } else {
            let missingRow = codexMenu.addItem(withTitle: "未检测到 Codex 项目", action: nil, keyEquivalent: "")
            missingRow.isEnabled = false
        }
        let syncItem = codexMenu.addItem(withTitle: "同步项目夹", action: #selector(toggleCodexProjectSync(_:)), keyEquivalent: "")
        syncItem.target = self
        ShortcutMenuAppearance.apply(to: syncItem, enabled: syncEnabled)
        codexItem.submenu = codexMenu

        let weChatItem = menu.addItem(withTitle: "微信关联", action: nil, keyEquivalent: "")
        weChatItem.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        let weChatMenu = NSMenu()
        weChatMenu.autoenablesItems = false
        let bindWeChat = weChatMenu.addItem(
            withTitle: "绑定微信",
            action: #selector(bindWeChat),
            keyEquivalent: ""
        )
        bindWeChat.target = self
        ShortcutMenuAppearance.apply(to: bindWeChat, enabled: weChat.isBound)
        let openWeChatLocation = weChatMenu.addItem(
            withTitle: "文件位置",
            action: #selector(openWeChatLocation),
            keyEquivalent: ""
        )
        openWeChatLocation.target = self
        openWeChatLocation.image = NSImage(
            systemSymbolName: "folder",
            accessibilityDescription: nil
        )
        weChatItem.submenu = weChatMenu

        let settingsItem = menu.addItem(withTitle: "设置", action: nil, keyEquivalent: "")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let settings = NSMenu()
        settings.autoenablesItems = false
        addShortcutToggle(
            to: settings,
            title: LaunchAtLoginService.menuTitle,
            enabled: launchAtLogin.isEnabled,
            action: #selector(toggleLaunchAtLogin(_:))
        )
        addShortcutToggle(
            to: settings,
            title: MouseWheelReverseStore.verticalTitle,
            enabled: mouseWheel.isVerticalEffective,
            action: #selector(toggleReverseVerticalWheel(_:))
        )
        addShortcutToggle(
            to: settings,
            title: MouseWheelReverseStore.horizontalTitle,
            enabled: mouseWheel.isHorizontalEffective,
            action: #selector(toggleReverseHorizontalWheel(_:))
        )
        let showAll = visibility.currentShowAllFiles()
        let toggleTitle = showAll ? "隐藏隐藏文件" : "显示隐藏文件"
        let toggle = settings.addItem(withTitle: toggleTitle, action: #selector(toggleHiddenVisibility), keyEquivalent: "")
        toggle.target = self
        toggle.image = NSImage(
            systemSymbolName: showAll ? "eye.slash" : "eye",
            accessibilityDescription: nil
        )
        addShortcutToggle(
            to: settings,
            title: "x/v移动文件",
            enabled: shortcuts.isFinderMoveEffective,
            action: #selector(toggleFinderMoveHotkeys(_:))
        )
        addShortcutToggle(
            to: settings,
            title: "双击⌘Q",
            enabled: shortcuts.isDoubleCommandQEffective,
            action: #selector(toggleDoubleCommandQ(_:))
        )
        addShortcutToggle(
            to: settings,
            title: "⌘Q强关访达",
            enabled: shortcuts.isFinderCommandQEffective,
            action: #selector(toggleFinderCommandQ(_:))
        )
        settingsItem.submenu = settings

        menu.addItem(.separator())

        let quit = menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)

        // 同步开启时，四项会改动手动根目录的功能均置灰；关闭时恢复。
        for item in manualRootItems {
            item.isEnabled = !syncEnabled
        }

        addBottomSpacer(to: menu)

        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    /// 读取剪贴板：若是纯文件夹路径（不带「」），设为根文件夹并通知。
    @objc private func readClipboard() {
        guard let raw = clipboard.read() else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 本应用复制路径会带「」包裹，这里只识别不带「」的纯路径，避免误设根。
        guard !text.hasPrefix("\u{300C}") else { return }
        guard fs.isExistingDirectory(text) else { return }
        store.save(text)
        notifyRootChanged(text)
    }

    @objc private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "选择作为根文件夹的目录"
        if panel.runModal() == .OK, let url = panel.url {
            store.save(url.path)
            notifyRootChanged(url.path)
        }
    }

    /// 重置初始目录：把根文件夹设回默认目录并通知。
    @objc private func resetRoot() {
        store.reset()
        notifyRootChanged(RootPathStore.defaultRoot)
    }

    /// 切换「同步项目夹」开关并更新勾选圆。
    @objc private func toggleCodexProjectSync(_ sender: NSMenuItem) {
        codexSync.syncEnabled = !codexSync.syncEnabled
        ShortcutMenuAppearance.apply(to: sender, enabled: codexSync.syncEnabled)
    }

    /// 按当前访达权威切换隐藏文件显示；失败则保持原状。
    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let result = launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
        ShortcutMenuAppearance.apply(to: sender, enabled: launchAtLogin.isEnabled)
        if case .failure(let error) = result {
            notifyLaunchAtLoginFailure(error)
        }
    }

    @objc private func toggleReverseVerticalWheel(_ sender: NSMenuItem) {
        _ = mouseWheel.setVerticalEnabled(!mouseWheel.isVerticalEffective)
        ShortcutMenuAppearance.apply(to: sender, enabled: mouseWheel.isVerticalEffective)
    }

    @objc private func toggleReverseHorizontalWheel(_ sender: NSMenuItem) {
        _ = mouseWheel.setHorizontalEnabled(!mouseWheel.isHorizontalEffective)
        ShortcutMenuAppearance.apply(to: sender, enabled: mouseWheel.isHorizontalEffective)
    }

    @objc private func toggleHiddenVisibility() {
        let next = !visibility.currentShowAllFiles()
        _ = visibility.setShowAllFiles(next)
    }

    @objc private func toggleFinderMoveHotkeys(_ sender: NSMenuItem) {
        _ = shortcuts.setFinderMoveEnabled(!shortcuts.isFinderMoveEffective)
        ShortcutMenuAppearance.apply(to: sender, enabled: shortcuts.isFinderMoveEffective)
    }

    @objc private func toggleDoubleCommandQ(_ sender: NSMenuItem) {
        _ = shortcuts.setDoubleCommandQEnabled(!shortcuts.isDoubleCommandQEffective)
        ShortcutMenuAppearance.apply(to: sender, enabled: shortcuts.isDoubleCommandQEffective)
    }

    @objc private func toggleFinderCommandQ(_ sender: NSMenuItem) {
        _ = shortcuts.setFinderCommandQEnabled(!shortcuts.isFinderCommandQEffective)
        ShortcutMenuAppearance.apply(to: sender, enabled: shortcuts.isFinderCommandQEffective)
    }

    @objc private func bindWeChat() {
        weChat.startBinding()
    }

    @objc private func openWeChatLocation() {
        weChat.openArchiveLocation()
    }

    /// 点击时重新解析访达单选项；失效则不改写根目录。
    @objc private func initRootFromFinder() {
        guard case .success(let directory) = finderSelection.resolveInitializationDirectory() else {
            return
        }
        store.save(directory)
        notifyRootChanged(directory)
    }

    // MARK: - 通知

    private func addShortcutToggle(to menu: NSMenu, title: String, enabled: Bool, action: Selector) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        ShortcutMenuAppearance.apply(to: item, enabled: enabled)
    }

    /// 在菜单末尾加一段底部留白，避免最后一项贴着菜单框底。
    private func addBottomSpacer(to menu: NSMenu) {
        let item = NSMenuItem()
        item.view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 8))
        item.isEnabled = false
        menu.addItem(item)
    }

    private func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyLaunchAtLoginFailure(_ error: LaunchAtLoginError) {
        let content = UNMutableNotificationContent()
        switch error {
        case .needsApproval:
            content.title = "无法开启开机自启"
            content.body = "请在“系统设置 → 通用 → 登录项与扩展”中允许 Tocode。"
        case .registerFailed:
            content.title = "无法开启开机自启"
            content.body = "登记登录项失败，开关保持关闭。"
        case .unregisterFailed:
            content.title = "无法关闭开机自启"
            content.body = "撤销登录项失败，请在系统设置中手动关闭。"
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "tocode.launch-at-login.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func notifyRootChanged(_ path: String) {
        let content = UNMutableNotificationContent()
        content.title = "根目录已更新"
        content.body = path
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
