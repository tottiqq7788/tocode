import AppKit
import UserNotifications

/// 菜单栏图标控制器：左键弹目录树，右键弹功能菜单。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let builder = MenuBuilder()
    private let fs = FileSystemService()
    private let clipboard = ClipboardService()
    private let store = RootPathStore()
    private let visibility = FinderVisibilityService()
    private let finderSelection = FinderSelectionService()
    private let shortcuts: GlobalShortcutService
    private let trackpadShortcuts: TrackpadShortcutControlling
    private let mouseWheel: MouseWheelReverseService
    private let launchAtLogin: LaunchAtLoginControlling
    private let weChat: WeChatAssociationControlling
    private let codex: CodexProjectService
    private let codexSync: CodexSyncSettingsStore
    private let codexModels: CodexModelSwitching
    private let codexRestarter: CodexApplicationRestarting
    private let screenBlackout: ScreenBlackoutService
    private var activeModelMenu: NSMenu?
    private var activeModelParentItem: NSMenuItem?
    private var currentModelID: String?
    private var modelDescriptors: [String: CodexModelDescriptor] = [:]
    private var modelLoadGeneration = UUID()
    private var isSwitchingModel = false
    private var commandPollingTimer: Timer?

    init(
        shortcuts: GlobalShortcutService,
        trackpadShortcuts: TrackpadShortcutControlling,
        mouseWheel: MouseWheelReverseService,
        launchAtLogin: LaunchAtLoginControlling = LaunchAtLoginService(),
        weChat: WeChatAssociationControlling,
        codex: CodexProjectService = CodexProjectService(),
        codexSync: CodexSyncSettingsStore = CodexSyncSettingsStore(),
        codexModels: CodexModelSwitching = CodexModelSwitchService(),
        codexRestarter: CodexApplicationRestarting = CodexApplicationRestarter(),
        screenBlackout: ScreenBlackoutService? = nil
    ) {
        self.shortcuts = shortcuts
        self.trackpadShortcuts = trackpadShortcuts
        self.mouseWheel = mouseWheel
        self.launchAtLogin = launchAtLogin
        self.weChat = weChat
        self.codex = codex
        self.codexSync = codexSync
        self.codexModels = codexModels
        self.codexRestarter = codexRestarter
        self.screenBlackout = screenBlackout ?? ScreenBlackoutService(overlay: ScreenBlackoutOverlay())
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
    /// 菜单打开期间用 eventTracking 模式的定时器轮询 Command 键状态，
    /// 实时在普通模式与删除模式之间切换；松开后恢复。
    private func showDirectoryMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let root = resolveDirectoryRoot()
        builder.fillRoot(menu, with: root, includeHidden: visibility.currentShowAllFiles())

        addBottomSpacer(to: menu)

        startCommandPolling()

        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }

        stopCommandPolling()
    }

    /// 在菜单跟踪期间轮询 Command 修饰键状态并同步到菜单构建器。
    private func startCommandPolling() {
        stopCommandPolling()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let isDelete = NSEvent.modifierFlags.contains(.command)
                self.builder.setDeleteMode(isDelete)
            }
        }
        RunLoop.current.add(timer, forMode: .eventTracking)
        commandPollingTimer = timer
    }

    private func stopCommandPolling() {
        commandPollingTimer?.invalidate()
        commandPollingTimer = nil
    }

    /// 右键：功能菜单。目录子菜单含「访达目录初始化」；「设置」含子项切换隐藏文件。
    private func showActionMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let syncEnabled = codexSync.syncEnabled

        // 访达：访问路径、复制路径、目录初始化。
        let finderItem = menu.addItem(withTitle: "访达", action: nil, keyEquivalent: "")
        finderItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        let finderMenu = NSMenu()
        finderMenu.autoenablesItems = false

        let accessPath = finderMenu.addItem(withTitle: "访问路径", action: #selector(openFinderAtRoot), keyEquivalent: "")
        accessPath.target = self
        accessPath.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)

        let copyFinderPath = finderMenu.addItem(withTitle: "复制路径", action: #selector(copyFinderSelectedPath), keyEquivalent: "")
        copyFinderPath.target = self
        copyFinderPath.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)

        if case .success = finderSelection.resolveInitializationDirectory() {
            let initRoot = finderMenu.addItem(withTitle: "目录初始化", action: #selector(initRootFromFinder), keyEquivalent: "")
            initRoot.target = self
            initRoot.image = NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: nil)
        }

        finderItem.submenu = finderMenu

        // 目录：读取剪贴板、更改目录、重置初始目录。
        let directoryItem = menu.addItem(withTitle: "目录", action: nil, keyEquivalent: "")
        directoryItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        let directoryMenu = NSMenu()
        directoryMenu.autoenablesItems = false

        let readClip = directoryMenu.addItem(withTitle: "读取剪贴板", action: #selector(readClipboard), keyEquivalent: "")
        readClip.target = self
        readClip.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)

        let changeDir = directoryMenu.addItem(withTitle: "更改目录", action: #selector(chooseRoot), keyEquivalent: "")
        changeDir.target = self
        changeDir.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)

        let resetRoot = directoryMenu.addItem(withTitle: "重置初始目录", action: #selector(resetRoot), keyEquivalent: "")
        resetRoot.target = self
        resetRoot.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)

        directoryItem.submenu = directoryMenu

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

        codexMenu.addItem(.separator())
        let modelState = try? codexModels.currentState()
        currentModelID = modelState?.liveModelID
        let modelTitle = modelState.map {
            CodexModelCatalog.displayName(for: $0.liveModelID)
        } ?? "模型不可用"
        let modelItem = codexMenu.addItem(withTitle: modelTitle, action: nil, keyEquivalent: "")
        modelItem.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
        if let modelState, !modelState.isConsistent {
            modelItem.toolTip = "Codex 实时配置与 CC Switch Provider 模板当前不一致"
        }
        let modelMenu = NSMenu()
        modelMenu.autoenablesItems = false
        modelMenu.delegate = self
        addModelStatusItem("悬停后实时加载", to: modelMenu)
        modelItem.submenu = modelMenu
        activeModelMenu = modelMenu
        activeModelParentItem = modelItem
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

        // mac 子菜单：临时黑屏与触控板轻点快捷键。
        let macItem = menu.addItem(withTitle: "mac", action: nil, keyEquivalent: "")
        macItem.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        let macMenu = NSMenu()
        macMenu.autoenablesItems = false
        let blackoutItem = macMenu.addItem(
            withTitle: "临时黑屏",
            action: #selector(activateScreenBlackout),
            keyEquivalent: ""
        )
        blackoutItem.target = self
        blackoutItem.image = NSImage(systemSymbolName: "display.trianglebadge.exclamationmark", accessibilityDescription: nil)

        let trackpadItem = macMenu.addItem(
            withTitle: "触控板",
            action: nil,
            keyEquivalent: ""
        )
        trackpadItem.image = NSImage(
            systemSymbolName: "hand.tap",
            accessibilityDescription: nil
        )
        let trackpadMenu = NSMenu()
        trackpadMenu.autoenablesItems = false
        for gesture in TrackpadTapGesture.allCases {
            let item = trackpadMenu.addItem(
                withTitle: gesture.title,
                action: #selector(configureTrackpadShortcut(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = gesture.rawValue
            ShortcutMenuAppearance.apply(
                to: item,
                enabled: trackpadShortcuts.shortcut(for: gesture) != nil
            )
        }
        trackpadItem.submenu = trackpadMenu
        macItem.submenu = macMenu

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

        // 同步开启时，「目录」父项置灰（父项禁用即无法展开下层）；关闭时恢复。
        directoryItem.isEnabled = !syncEnabled

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

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === activeModelMenu else { return }
        loadCodexModels(into: menu)
    }

    private func loadCodexModels(into menu: NSMenu) {
        guard !isSwitchingModel else {
            menu.removeAllItems()
            addModelStatusItem("正在切换模型…", to: menu)
            return
        }

        menu.removeAllItems()
        addModelStatusItem("正在从 Anker 加载…", to: menu)
        let generation = UUID()
        modelLoadGeneration = generation

        if let state = try? codexModels.currentState() {
            currentModelID = state.liveModelID
            activeModelParentItem?.title = CodexModelCatalog.displayName(for: state.liveModelID)
            activeModelParentItem?.toolTip = state.isConsistent
                ? nil
                : "Codex 实时配置与 CC Switch Provider 模板当前不一致"
        }

        codexModels.fetchModels { [weak self, weak menu] result in
            DispatchQueue.main.async {
                guard let self,
                      let menu,
                      menu === self.activeModelMenu,
                      generation == self.modelLoadGeneration else {
                    return
                }
                switch result {
                case .success(let models):
                    self.renderCodexModels(models, in: menu)
                case .failure(let error):
                    self.renderModelLoadFailure(error, in: menu)
                }
            }
        }
    }

    private func renderCodexModels(_ models: [CodexModelDescriptor], in menu: NSMenu) {
        menu.removeAllItems()
        modelDescriptors = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        let grouped = Dictionary(grouping: models, by: \.source)

        for source in CodexModelSource.allCases {
            guard let sourceModels = grouped[source], !sourceModels.isEmpty else { continue }
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            let header = menu.addItem(withTitle: source.rawValue, action: nil, keyEquivalent: "")
            header.isEnabled = false

            for model in sourceModels {
                let item = menu.addItem(
                    withTitle: model.displayName,
                    action: #selector(selectCodexModel(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = model.id
                item.toolTip = model.id

                if model.id == currentModelID {
                    item.state = .on
                    item.isEnabled = false
                    item.toolTip = "\(model.id)\n当前模型"
                    continue
                }
                switch model.compatibility {
                case .verified:
                    item.isEnabled = true
                case .unverified:
                    item.isEnabled = true
                    item.image = NSImage(
                        systemSymbolName: "exclamationmark.triangle",
                        accessibilityDescription: "未验证"
                    )
                    item.toolTip = "\(model.id)\n尚未验证 Codex /responses 与工具调用兼容性"
                case .unsupported(let reason):
                    item.isEnabled = false
                    item.image = NSImage(
                        systemSymbolName: "nosign",
                        accessibilityDescription: "不可作为主模型"
                    )
                    item.toolTip = "\(model.id)\n\(reason)"
                }
            }
        }
    }

    private func renderModelLoadFailure(_ error: Error, in menu: NSMenu) {
        menu.removeAllItems()
        addModelStatusItem(error.localizedDescription, to: menu)
        let retry = menu.addItem(
            withTitle: "重试",
            action: #selector(retryCodexModelLoad),
            keyEquivalent: ""
        )
        retry.target = self
        retry.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
    }

    private func addModelStatusItem(_ title: String, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
    }

    @objc private func retryCodexModelLoad() {
        guard let menu = activeModelMenu else { return }
        loadCodexModels(into: menu)
    }

    @objc private func selectCodexModel(_ sender: NSMenuItem) {
        guard !isSwitchingModel,
              let modelID = sender.representedObject as? String,
              let descriptor = modelDescriptors[modelID],
              modelID != currentModelID else {
            return
        }

        if descriptor.compatibility == .unverified {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "该模型尚未验证"
            alert.informativeText = "\(descriptor.displayName) 可能不兼容 Codex /responses、工具调用或模型 metadata。仍要切换并在 2 秒后强制重启 Codex吗？"
            alert.addButton(withTitle: "继续切换")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        isSwitchingModel = true
        activeModelMenu?.items.forEach { $0.isEnabled = false }
        DispatchQueue.global(qos: .userInitiated).async { [codexModels] in
            let result = Result { try codexModels.switchModel(to: modelID) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    self.currentModelID = modelID
                    self.activeModelParentItem?.title = descriptor.displayName
                    self.notifyCodexModelSwitchScheduled(descriptor.displayName)
                    self.codexRestarter.forceRestart(after: 2) { restartResult in
                        DispatchQueue.main.async {
                            self.isSwitchingModel = false
                            if case .failure(let error) = restartResult {
                                self.notifyCodexModelFailure(error.localizedDescription)
                            }
                        }
                    }
                case .failure(let error):
                    self.isSwitchingModel = false
                    self.notifyCodexModelFailure(error.localizedDescription)
                }
            }
        }
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

    /// 显示临时黑屏；再次点击时若已显示则为 no-op。
    @objc private func activateScreenBlackout() {
        screenBlackout.activate()
    }

    @objc private func configureTrackpadShortcut(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? Int,
            let gesture = TrackpadTapGesture(rawValue: rawValue)
        else {
            return
        }

        let existing = trackpadShortcuts.shortcut(for: gesture)
        switch ShortcutRecorderPrompt.prompt(for: gesture, existing: existing) {
        case .save(let shortcut):
            _ = trackpadShortcuts.setShortcut(shortcut, for: gesture)
        case .clear:
            trackpadShortcuts.clearShortcut(for: gesture)
        case .cancel:
            break
        }
        ShortcutMenuAppearance.apply(
            to: sender,
            enabled: trackpadShortcuts.shortcut(for: gesture) != nil
        )
    }

    /// 复制当前访达选中文件或文件夹本身的绝对路径。
    @objc private func copyFinderSelectedPath() {
        guard case .success(let path) = finderSelection.resolveSelectedItemPath() else { return }
        clipboard.copyPath(path)
    }

    /// 在访达中打开当前左键目录对应的根目录。
    @objc private func openFinderAtRoot() {
        let root = resolveDirectoryRoot()
        guard fs.isExistingDirectory(root) else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root)
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

    private func notifyCodexModelSwitchScheduled(_ displayName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Codex 模型已切换"
        content.body = "\(displayName)；2 秒后将强制重启 Codex。"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "tocode.codex-model.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func notifyCodexModelFailure(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Codex 模型切换失败"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "tocode.codex-model.failure.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
