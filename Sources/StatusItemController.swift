import AppKit
import UniformTypeIdentifiers
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
    private let keyboardRemaps: KeyboardShortcutRemapControlling
    private let mouseWheel: MouseWheelReverseService
    private let dockAutohideRestrict: DockAutohideRestrictService
    private let macTimers: MacTimerControlling
    private let shortcutPoster: TrackpadShortcutEventPosting
    private let launchAtLogin: LaunchAtLoginControlling
    private let weChat: WeChatAssociationControlling
    private let codex: CodexProjectService
    private let codexSync: CodexSyncSettingsStore
    private let finderFollow: FinderFollowSettingsStore
    private let codexModels: CodexModelSwitching
    private let codexRestarter: CodexApplicationRestarting
    private let ankerCredentials: AnkerCredentialUpdating
    private let extendedSettings: ExtendedSettingsStore
    private let screenBlackout: ScreenBlackoutService
    private let commandExecutor: TocodeCommandExecutor
    private let actionDispatcher = KeyboardMappingActionDispatcher()
    private var activeModelMenu: NSMenu?
    private var activeModelParentItem: NSMenuItem?
    private var currentModelID: String?
    private var modelDescriptors: [String: CodexModelDescriptor] = [:]
    private var modelLoadGeneration = UUID()
    private var isSwitchingModel = false
    private var isUpdatingCredentials = false
    private var modifierPollingTimer: Timer?
    private var timerMenuRefreshTimer: Timer?
    private weak var liveTimerMenu: NSMenu?
    private var liveTimerMenuItems: [UUID: NSMenuItem] = [:]
    private weak var liveModelMenuItem: NSMenuItem?
    private static let ankerKeyItemID = "tocode.extended.ankerKey"
    private static let secretsFolderItemID = "tocode.extended.secretsFolder"
    private static let codexModelItemID = "tocode.extended.codexModel"
    private static let portableSettingsType =
        UTType(tag: "tocode", tagClass: .filenameExtension, conformingTo: .json) ?? .json

    init(
        shortcuts: GlobalShortcutService,
        trackpadShortcuts: TrackpadShortcutControlling,
        keyboardRemaps: KeyboardShortcutRemapControlling,
        mouseWheel: MouseWheelReverseService,
        dockAutohideRestrict: DockAutohideRestrictService = DockAutohideRestrictService(),
        macTimers: MacTimerControlling = MacTimerService(),
        shortcutPoster: TrackpadShortcutEventPosting = SystemTrackpadShortcutEventPoster(),
        launchAtLogin: LaunchAtLoginControlling = LaunchAtLoginService(),
        weChat: WeChatAssociationControlling,
        codex: CodexProjectService = CodexProjectService(),
        codexSync: CodexSyncSettingsStore = CodexSyncSettingsStore(),
        finderFollow: FinderFollowSettingsStore = FinderFollowSettingsStore(),
        codexModels: CodexModelSwitching = CodexModelSwitchService(),
        codexRestarter: CodexApplicationRestarting = CodexApplicationRestarter(),
        ankerCredentials: AnkerCredentialUpdating = AnkerCredentialService(),
        extendedSettings: ExtendedSettingsStore = ExtendedSettingsStore(),
        screenBlackout: ScreenBlackoutService? = nil,
        commandExecutor: TocodeCommandExecutor
    ) {
        self.shortcuts = shortcuts
        self.trackpadShortcuts = trackpadShortcuts
        self.keyboardRemaps = keyboardRemaps
        self.mouseWheel = mouseWheel
        self.dockAutohideRestrict = dockAutohideRestrict
        self.macTimers = macTimers
        self.shortcutPoster = shortcutPoster
        self.launchAtLogin = launchAtLogin
        self.weChat = weChat
        self.codex = codex
        self.codexSync = codexSync
        self.finderFollow = finderFollow
        self.codexModels = codexModels
        self.codexRestarter = codexRestarter
        self.ankerCredentials = ankerCredentials
        self.extendedSettings = extendedSettings
        self.screenBlackout = screenBlackout ?? ScreenBlackoutService(overlay: ScreenBlackoutOverlay())
        self.commandExecutor = commandExecutor
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        actionDispatcher.execute = { [weak self] command in
            guard let self else {
                return .failure(.operationFailed("命令执行器不可用"))
            }
            return self.commandExecutor.execute(command)
        }
        actionDispatcher.notify = { [weak self] title, body in
            self?.notifyMappedAction(title, body)
        }
        actionDispatcher.openFinderAtRoot = { [weak self] in
            self?.openFinderAtRoot()
        }
        actionDispatcher.copyFinderSelectedPath = { [weak self] in
            self?.copyFinderSelectedPath()
        }
        actionDispatcher.readClipboardRoot = { [weak self] in
            self?.readClipboard()
        }
        actionDispatcher.activateBlackout = { [weak self] in
            self?.screenBlackout.activate()
        }
        macTimers.onChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshLiveTimerMenuItems()
            }
        }
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

    /// 左键根目录解析：默认固定目录；访达/Codex 前台且对应跟随开启时临时接管。
    private func resolveDirectoryRoot() -> String {
        let frontmost = DirectoryRootResolver.frontmost(
            fromBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        )
        let finderDirectory: String?
        if frontmost == .finder,
           case .success(let path) = finderSelection.resolveInitializationDirectory() {
            finderDirectory = path
        } else {
            finderDirectory = nil
        }
        let codexRoot: String?
        if frontmost == .codex {
            codexRoot = codex.resolveProject()?.rootPath
        } else {
            codexRoot = nil
        }
        return DirectoryRootResolver.resolve(
            frontmost: frontmost,
            finderFollowEnabled: finderFollow.followEnabled,
            finderDirectory: finderDirectory,
            codexFollowEnabled: codexSync.syncEnabled,
            codexRoot: codexRoot,
            manualRoot: store.resolveRoot(isDirectory: { fs.isExistingDirectory($0) })
        )
    }

    /// 左键：弹出目录树（始终从当前根第一层）；根菜单含「历史」「配置」与「新增」。
    /// Shift 连续多选尽量保持同一菜单；若系统仍关闭则立刻再弹同一菜单。
    private func showDirectoryMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let root = resolveDirectoryRoot()
        builder.makeRootConfigItem = { [weak self] in
            self?.makeRootConfigMenuItem() ?? NSMenuItem()
        }
        builder.fillRoot(menu, with: root, includeHidden: visibility.currentShowAllFiles())
        builder.makeRootConfigItem = nil
        addBottomSpacer(to: menu)

        startModifierPolling()
        builder.resetMultiCopySession()

        repeat {
            builder.beginTracking(rootMenu: menu)
            if let button = statusItem.button {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
            }
            builder.endTracking()
        } while builder.consumeSameMenuRepopRequest()

        builder.resetMultiCopySession()
        stopModifierPolling()
    }

    private func makeRootConfigMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "配置", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: "配置")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let copyPath = submenu.addItem(
            withTitle: "复制路径",
            action: #selector(copyFinderSelectedPath),
            keyEquivalent: ""
        )
        copyPath.target = self
        copyPath.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)

        submenu.addItem(.separator())

        let readClip = submenu.addItem(
            withTitle: "读取剪贴板",
            action: #selector(readClipboard),
            keyEquivalent: ""
        )
        readClip.target = self
        readClip.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)

        let changeDir = submenu.addItem(
            withTitle: "更改目录",
            action: #selector(chooseRoot),
            keyEquivalent: ""
        )
        changeDir.target = self
        changeDir.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)

        let resetRoot = submenu.addItem(
            withTitle: "重置初始目录",
            action: #selector(resetRoot),
            keyEquivalent: ""
        )
        resetRoot.target = self
        resetRoot.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: nil)

        submenu.addItem(.separator())

        addShortcutToggle(
            to: submenu,
            title: "访达跟随",
            enabled: finderFollow.followEnabled,
            action: #selector(toggleFinderFollow(_:))
        )
        addShortcutToggle(
            to: submenu,
            title: "codex跟随",
            enabled: codexSync.syncEnabled,
            action: #selector(toggleCodexProjectSync(_:))
        )

        item.submenu = submenu
        return item
    }

    /// 在菜单跟踪期间轮询 Option/Command 并同步到菜单构建器。Option 优先于 Command。
    private func startModifierPolling() {
        stopModifierPolling()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let flags = NSEvent.modifierFlags
                self.builder.setMode(.resolve(
                    option: flags.contains(.option),
                    command: flags.contains(.command)
                ))
            }
        }
        RunLoop.current.add(timer, forMode: .eventTracking)
        modifierPollingTimer = timer
    }

    private func stopModifierPolling() {
        modifierPollingTimer?.invalidate()
        modifierPollingTimer = nil
    }

    /// 右键：功能菜单。访达 / 输入 / 工具 / AK / 微信 / 设置。
    private func showActionMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 访达
        let finderItem = menu.addItem(withTitle: "访达", action: nil, keyEquivalent: "")
        finderItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        let finderMenu = NSMenu()
        finderMenu.autoenablesItems = false
        let showAll = visibility.currentShowAllFiles()
        let toggleTitle = showAll ? "隐藏隐藏文件" : "显示隐藏文件"
        let toggle = finderMenu.addItem(withTitle: toggleTitle, action: #selector(toggleHiddenVisibility), keyEquivalent: "")
        toggle.target = self
        toggle.image = NSImage(
            systemSymbolName: showAll ? "eye.slash" : "eye",
            accessibilityDescription: nil
        )
        addShortcutToggle(
            to: finderMenu,
            title: "x/v移动文件",
            enabled: shortcuts.isFinderMoveEffective,
            action: #selector(toggleFinderMoveHotkeys(_:))
        )
        addShortcutToggle(
            to: finderMenu,
            title: "⌘Q强关访达",
            enabled: shortcuts.isFinderCommandQEffective,
            action: #selector(toggleFinderCommandQ(_:))
        )
        finderItem.submenu = finderMenu

        // 输入
        let inputItem = menu.addItem(withTitle: "输入", action: nil, keyEquivalent: "")
        inputItem.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        let inputMenu = NSMenu()
        inputMenu.autoenablesItems = false

        let trackpadItem = inputMenu.addItem(withTitle: "触控板", action: nil, keyEquivalent: "")
        trackpadItem.image = NSImage(systemSymbolName: "hand.tap", accessibilityDescription: nil)
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
            applyTrackpadMenuAppearance(to: item, gesture: gesture)
        }
        trackpadItem.submenu = trackpadMenu

        let keyboardItem = inputMenu.addItem(withTitle: "键盘", action: nil, keyEquivalent: "")
        keyboardItem.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        let keyboardMenu = NSMenu()
        keyboardMenu.autoenablesItems = false
        let addKeyboardMapping = keyboardMenu.addItem(
            withTitle: "新增",
            action: #selector(createKeyboardMapping),
            keyEquivalent: ""
        )
        addKeyboardMapping.target = self
        addKeyboardMapping.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新增")
        if !keyboardRemaps.mappings.isEmpty {
            keyboardMenu.addItem(.separator())
            for mapping in keyboardRemaps.mappings {
                let item = keyboardMenu.addItem(
                    withTitle: mapping.name,
                    action: #selector(editKeyboardMapping(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = mapping.id.uuidString
                let symbolName: String
                switch mapping.target {
                case .shortcut:
                    symbolName = "checkmark.circle.fill"
                case .action(let action):
                    symbolName = action.menuSymbolName
                }
                item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "已配置")
                item.toolTip = "\(mapping.source.displayName) → \(mapping.target.displayText)"
            }
        }
        keyboardItem.submenu = keyboardMenu

        addShortcutToggle(
            to: inputMenu,
            title: MouseWheelReverseStore.verticalTitle,
            enabled: mouseWheel.isVerticalEffective,
            action: #selector(toggleReverseVerticalWheel(_:))
        )
        addShortcutToggle(
            to: inputMenu,
            title: MouseWheelReverseStore.horizontalTitle,
            enabled: mouseWheel.isHorizontalEffective,
            action: #selector(toggleReverseHorizontalWheel(_:))
        )
        addShortcutToggle(
            to: inputMenu,
            title: "双击⌘Q",
            enabled: shortcuts.isDoubleCommandQEffective,
            action: #selector(toggleDoubleCommandQ(_:))
        )
        inputItem.submenu = inputMenu

        // 工具：定时器置顶，其后临时黑屏与程序坞限制。
        let toolsItem = menu.addItem(withTitle: "工具", action: nil, keyEquivalent: "")
        toolsItem.image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: nil)
        let toolsMenu = NSMenu()
        toolsMenu.autoenablesItems = false

        let timerItem = toolsMenu.addItem(withTitle: "定时器", action: nil, keyEquivalent: "")
        timerItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        let timerMenu = NSMenu()
        timerMenu.autoenablesItems = false
        let addTimer = timerMenu.addItem(
            withTitle: "新增",
            action: #selector(createMacTimer),
            keyEquivalent: ""
        )
        addTimer.target = self
        addTimer.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新增")
        liveTimerMenuItems.removeAll()
        if !macTimers.timers.isEmpty {
            timerMenu.addItem(.separator())
            let now = Date()
            for timer in macTimers.timers {
                let item = timerMenu.addItem(
                    withTitle: MacTimerRemaining.menuTitle(
                        name: timer.name,
                        fireAt: timer.fireAt,
                        now: now
                    ),
                    action: #selector(editMacTimer(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = timer.id.uuidString
                ShortcutMenuAppearance.apply(to: item, enabled: timer.isRunning)
                item.toolTip = timer.target.displayText
                liveTimerMenuItems[timer.id] = item
            }
        }
        timerItem.submenu = timerMenu
        liveTimerMenu = timerMenu

        let blackoutItem = toolsMenu.addItem(
            withTitle: "临时黑屏",
            action: #selector(activateScreenBlackout),
            keyEquivalent: ""
        )
        blackoutItem.target = self
        blackoutItem.image = NSImage(systemSymbolName: "display.trianglebadge.exclamationmark", accessibilityDescription: nil)

        addShortcutToggle(
            to: toolsMenu,
            title: DockAutohideRestrictStore.menuTitle,
            enabled: dockAutohideRestrict.isEffective,
            action: #selector(toggleDockAutohideRestrict(_:))
        )
        toolsItem.submenu = toolsMenu

        // AK → AK-模型（AK 门控）
        activeModelMenu = nil
        activeModelParentItem = nil
        currentModelID = nil
        liveModelMenuItem = nil
        if extendedSettings.akEnabled {
            let akItem = menu.addItem(
                withTitle: ExtendedSettingsStore.topLevelFolderTitle,
                action: nil,
                keyEquivalent: ""
            )
            akItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
            let akMenu = NSMenu()
            akMenu.autoenablesItems = false

            let modelItem = akMenu.addItem(
                withTitle: ExtendedSettingsStore.modelMenuTitle,
                action: nil,
                keyEquivalent: ""
            )
            modelItem.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
            modelItem.representedObject = Self.codexModelItemID
            let modelMenu = NSMenu()
            modelMenu.autoenablesItems = false
            modelMenu.delegate = self
            addModelStatusItem("悬停后实时加载", to: modelMenu)
            modelItem.submenu = modelMenu
            akItem.submenu = akMenu
            activeModelMenu = modelMenu
            activeModelParentItem = modelItem
            liveModelMenuItem = akItem
            if let state = try? codexModels.currentState() {
                currentModelID = state.liveModelID
                if !state.isConsistent {
                    modelItem.toolTip = "Codex 实时配置与 CC Switch Provider 模板当前不一致"
                }
            }

            let secretsFolder = NSMenuItem(
                title: ExtendedSettingsStore.secretsFolderTitle,
                action: nil,
                keyEquivalent: ""
            )
            secretsFolder.image = NSImage(systemSymbolName: "key", accessibilityDescription: nil)
            secretsFolder.representedObject = Self.secretsFolderItemID
            let secretsMenu = NSMenu()
            secretsMenu.autoenablesItems = false
            secretsMenu.addItem(makeAnkerKeyItem())
            secretsFolder.submenu = secretsMenu
            akMenu.addItem(secretsFolder)
        }

        // 微信
        let weChatItem = menu.addItem(withTitle: "微信", action: nil, keyEquivalent: "")
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
        openWeChatLocation.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        weChatItem.submenu = weChatMenu

        // 设置
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
        let configItem = settings.addItem(
            withTitle: TocodePortableSettings.folderTitle,
            action: nil,
            keyEquivalent: ""
        )
        configItem.image = NSImage(
            systemSymbolName: "doc.badge.gearshape",
            accessibilityDescription: TocodePortableSettings.folderTitle
        )
        let configMenu = NSMenu()
        configMenu.autoenablesItems = false
        let exportSettings = configMenu.addItem(
            withTitle: TocodePortableSettings.exportTitle,
            action: #selector(exportPortableSettings),
            keyEquivalent: ""
        )
        exportSettings.target = self
        exportSettings.image = NSImage(
            systemSymbolName: "square.and.arrow.up",
            accessibilityDescription: TocodePortableSettings.exportTitle
        )
        let importSettings = configMenu.addItem(
            withTitle: TocodePortableSettings.importTitle,
            action: #selector(importPortableSettings),
            keyEquivalent: ""
        )
        importSettings.target = self
        importSettings.image = NSImage(
            systemSymbolName: "square.and.arrow.down",
            accessibilityDescription: TocodePortableSettings.importTitle
        )
        configItem.submenu = configMenu
        let extendedItem = settings.addItem(
            withTitle: ExtendedSettingsStore.folderTitle,
            action: nil,
            keyEquivalent: ""
        )
        extendedItem.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        let extendedMenu = NSMenu()
        extendedMenu.autoenablesItems = false
        addShortcutToggle(
            to: extendedMenu,
            title: ExtendedSettingsStore.akTitle,
            enabled: extendedSettings.akEnabled,
            action: #selector(toggleExtendedSettingAK(_:))
        )
        extendedItem.submenu = extendedMenu
        let manual = settings.addItem(
            withTitle: UserManual.menuTitle,
            action: #selector(showUserManual),
            keyEquivalent: ""
        )
        manual.target = self
        manual.image = NSImage(systemSymbolName: "book", accessibilityDescription: UserManual.menuTitle)
        settingsItem.submenu = settings

        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)

        addBottomSpacer(to: menu)

        startTimerMenuRefresh()
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
        stopTimerMenuRefresh()
        liveModelMenuItem = nil
        liveTimerMenu = nil
        liveTimerMenuItems.removeAll()
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

    /// 切换「codex跟随」开关并更新勾选圆。
    @objc private func toggleCodexProjectSync(_ sender: NSMenuItem) {
        codexSync.syncEnabled = !codexSync.syncEnabled
        ShortcutMenuAppearance.apply(to: sender, enabled: codexSync.syncEnabled)
    }

    /// 切换「访达跟随」开关并更新勾选圆。
    @objc private func toggleFinderFollow(_ sender: NSMenuItem) {
        finderFollow.followEnabled = !finderFollow.followEnabled
        ShortcutMenuAppearance.apply(to: sender, enabled: finderFollow.followEnabled)
    }

    @objc private func toggleExtendedSettingAK(_ sender: NSMenuItem) {
        extendedSettings.akEnabled = !extendedSettings.akEnabled
        ShortcutMenuAppearance.apply(to: sender, enabled: extendedSettings.akEnabled)
    }

    private var ankerKeyItemTitle: String {
        isUpdatingCredentials
            ? "\(AnkerCredentialPrompt.menuTitle)（保存中…）"
            : AnkerCredentialPrompt.menuTitle
    }

    private func makeAnkerKeyItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: ankerKeyItemTitle,
            action: #selector(changeAnkerCredential),
            keyEquivalent: ""
        )
        item.target = self
        item.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
        item.isEnabled = !isUpdatingCredentials && !isSwitchingModel
        item.representedObject = Self.ankerKeyItemID
        return item
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
            activeModelParentItem?.title = ExtendedSettingsStore.modelMenuTitle
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
        guard !isSwitchingModel, !isUpdatingCredentials,
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
                    self.activeModelParentItem?.title = ExtendedSettingsStore.modelMenuTitle
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

    @objc private func changeAnkerCredential() {
        guard !isUpdatingCredentials, !isSwitchingModel,
              let key = AnkerCredentialPrompt.prompt() else { return }
        isUpdatingCredentials = true
        DispatchQueue.global(qos: .userInitiated).async { [ankerCredentials] in
            let result = Result { try ankerCredentials.update(key) }
            DispatchQueue.main.async { [weak self] in
                self?.isUpdatingCredentials = false
                AnkerCredentialPrompt.showResult(result)
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

    @objc private func showUserManual() {
        UserManual.present()
    }

    @objc private func exportPortableSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.portableSettingsType]
        panel.nameFieldStringValue = "tocode-settings.tocode"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let settings = TocodePortableSettingsTransfer.make(from: TocodePreferences.shared)
            try TocodePortableSettingsTransfer.encode(settings).write(to: url, options: .atomic)
        } catch {
            presentSettingsAlert(title: "导出失败", message: error.localizedDescription)
        }
    }

    @objc private func importPortableSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.portableSettingsType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        let settings: TocodePortableSettings
        do {
            settings = try TocodePortableSettingsTransfer.decode(Data(contentsOf: url))
        } catch {
            presentSettingsAlert(title: "导入失败", message: error.localizedDescription)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "覆盖可分享配置？"
        alert.informativeText = "将整段替换键盘映射、触控板轻点、快捷键开关与滚轮设置，且不可自动撤销。根目录、开机自启、微信、密钥与拓展设置不受影响。"
        alert.addButton(withTitle: "覆盖")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        TocodePortableSettingsTransfer.apply(settings, to: TocodePreferences.shared)
        shortcuts.applySavedSettings()
        trackpadShortcuts.applySavedSettings()
        keyboardRemaps.applySavedSettings()
        mouseWheel.applySavedSettings()
    }

    private func presentSettingsAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
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

    @objc private func toggleDockAutohideRestrict(_ sender: NSMenuItem) {
        _ = dockAutohideRestrict.setEnabled(!dockAutohideRestrict.isEffective)
        ShortcutMenuAppearance.apply(to: sender, enabled: dockAutohideRestrict.isEffective)
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

        shortcuts.setInputCaptureSuspended(true)
        keyboardRemaps.setInputCaptureSuspended(true)
        defer {
            keyboardRemaps.setInputCaptureSuspended(false)
            shortcuts.setInputCaptureSuspended(false)
        }

        let existing = trackpadShortcuts.binding(for: gesture)
        switch ShortcutRecorderPrompt.prompt(for: gesture, existing: existing) {
        case .save(let target):
            _ = trackpadShortcuts.setBinding(target, for: gesture)
        case .clear:
            trackpadShortcuts.clearBinding(for: gesture)
        case .cancel:
            break
        }
        applyTrackpadMenuAppearance(to: sender, gesture: gesture)
    }

    private func applyTrackpadMenuAppearance(to item: NSMenuItem, gesture: TrackpadTapGesture) {
        let binding = trackpadShortcuts.binding(for: gesture)
        ShortcutMenuAppearance.apply(to: item, enabled: binding != nil)
        item.toolTip = binding?.displayText
    }

    @objc private func createKeyboardMapping() {
        presentKeyboardMappingEditor(
            draft: KeyboardShortcutMappingDraft(),
            isEditing: false
        )
    }

    @objc private func editKeyboardMapping(_ sender: NSMenuItem) {
        guard
            let rawID = sender.representedObject as? String,
            let id = UUID(uuidString: rawID),
            let mapping = keyboardRemaps.mappings.first(where: { $0.id == id })
        else {
            return
        }
        presentKeyboardMappingEditor(
            draft: KeyboardShortcutMappingDraft(mapping: mapping),
            isEditing: true
        )
    }

    private func presentKeyboardMappingEditor(
        draft initialDraft: KeyboardShortcutMappingDraft,
        isEditing: Bool
    ) {
        shortcuts.setInputCaptureSuspended(true)
        keyboardRemaps.setInputCaptureSuspended(true)
        defer {
            keyboardRemaps.setInputCaptureSuspended(false)
            shortcuts.setInputCaptureSuspended(false)
        }

        var draft = initialDraft
        while true {
            switch KeyboardShortcutMappingPrompt.prompt(
                draft: draft,
                isEditing: isEditing
            ) {
            case .save(let candidate):
                switch keyboardRemaps.saveMapping(candidate) {
                case .success:
                    return
                case .failure(let error):
                    presentKeyboardMappingError(error)
                    draft = candidate
                }
            case .delete:
                if let id = draft.id {
                    keyboardRemaps.deleteMapping(id: id)
                }
                return
            case .cancel:
                return
            }
        }
    }

    private func presentKeyboardMappingError(
        _ error: KeyboardShortcutMappingValidationError
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法保存键盘映射"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func createMacTimer() {
        presentMacTimerEditor(
            draft: MacTimerDraft(minutesText: "10"),
            mode: .create
        )
    }

    @objc private func editMacTimer(_ sender: NSMenuItem) {
        guard
            let rawID = sender.representedObject as? String,
            let id = UUID(uuidString: rawID),
            let timer = macTimers.timers.first(where: { $0.id == id })
        else {
            return
        }
        let mode: MacTimerPromptMode = timer.isRunning ? .editRunning : .editIdle
        presentMacTimerEditor(draft: MacTimerDraft(timer: timer), mode: mode)
    }

    private func presentMacTimerEditor(draft initialDraft: MacTimerDraft, mode: MacTimerPromptMode) {
        shortcuts.setInputCaptureSuspended(true)
        keyboardRemaps.setInputCaptureSuspended(true)
        defer {
            keyboardRemaps.setInputCaptureSuspended(false)
            shortcuts.setInputCaptureSuspended(false)
        }

        var draft = initialDraft
        while true {
            switch MacTimerPrompt.prompt(draft: draft, mode: mode) {
            case .save(let candidate):
                switch macTimers.saveAndStart(candidate) {
                case .success:
                    return
                case .failure(let error):
                    presentMacTimerError(error)
                    draft = candidate
                }
            case .delete:
                if let id = draft.id {
                    macTimers.delete(id: id)
                }
                return
            case .cancel:
                return
            }
        }
    }

    private func presentMacTimerError(_ error: MacTimerValidationError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法保存定时任务"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func startTimerMenuRefresh() {
        stopTimerMenuRefresh()
        guard liveTimerMenuItems.contains(where: { pair in
            macTimers.timers.contains { $0.id == pair.key && $0.isRunning }
        }) else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshLiveTimerMenuItems()
            }
        }
        RunLoop.current.add(timer, forMode: .eventTracking)
        timerMenuRefreshTimer = timer
    }

    private func stopTimerMenuRefresh() {
        timerMenuRefreshTimer?.invalidate()
        timerMenuRefreshTimer = nil
    }

    private func refreshLiveTimerMenuItems() {
        let now = Date()
        let timersByID = Dictionary(uniqueKeysWithValues: macTimers.timers.map { ($0.id, $0) })
        for (id, item) in liveTimerMenuItems {
            guard let timer = timersByID[id] else { continue }
            item.title = MacTimerRemaining.menuTitle(
                name: timer.name,
                fireAt: timer.fireAt,
                now: now
            )
            ShortcutMenuAppearance.apply(to: item, enabled: timer.isRunning)
            item.toolTip = timer.target.displayText
            item.menu?.itemChanged(item)
        }
    }

    /// 复制当前访达选中文件或文件夹本身的绝对路径。
    @objc private func copyFinderSelectedPath() {
        guard case .success(let path) = finderSelection.resolveSelectedItemPath() else { return }
        clipboard.copyPath(path)
    }

    func performMappedAction(_ action: KeyboardMappingAction) {
        actionDispatcher.perform(action)
    }

    /// 定时器到点：桌面切换与快捷键合成走 poster，其余走动作 dispatcher。
    func performMappedTarget(_ target: KeyboardShortcutMappingTarget) {
        switch target.remapStep() {
        case .emit(let shortcut):
            if !shortcutPoster.post(shortcut) {
                notifyMappedAction("定时器执行失败", "目标快捷键未能发送。")
            }
        case .invoke(let action):
            performMappedAction(action)
        case .pass, .suppress:
            break
        }
    }

    /// 在访达中打开当前左键目录对应的根目录。
    @objc private func openFinderAtRoot() {
        let root = resolveDirectoryRoot()
        guard fs.isExistingDirectory(root) else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root)
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

    private func notifyMappedAction(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "tocode.keyboard-mapping.\(UUID().uuidString)",
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
