import AppKit
import UniformTypeIdentifiers
import UserNotifications

/// 菜单栏图标控制器：左键弹目录树，按住 totti 时左键弹桌面窗口菜单，右键弹功能菜单。
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let terminalWindows: DirectoryTerminalWindowStore
    private let terminalFrontWindow: DirectoryTerminalFrontWindowReading
    private let builder: MenuBuilder
    private let fs = FileSystemService()
    private let clipboard = ClipboardService()
    private let store = RootPathStore()
    private let visibility = FinderVisibilityService()
    private let finderSelection = FinderSelectionService()
    private let shortcuts: GlobalShortcutService
    private let trackpadShortcuts: TrackpadShortcutControlling
    private let keyboardRemaps: KeyboardShortcutRemapControlling
    private let spaceModifier: SpaceModifierControlling
    private let mouseWheel: MouseWheelReverseService
    private let dockAutohideRestrict: DockAutohideRestrictService
    private let macTimers: MacTimerControlling
    private let shortcutPoster: TrackpadShortcutEventPosting
    private let launchAtLogin: LaunchAtLoginControlling
    private let weChat: WeChatAssociationControlling
    private let remoteControl: RemoteControlService
    private let codex: CodexProjectService
    private let codexSync: CodexSyncSettingsStore
    private let finderFollow: FinderFollowSettingsStore
    private let terminalFollow: TerminalFollowSettingsStore
    private let hermesFollow: HermesFollowSettingsStore
    private let hermesProjects: HermesProjectService
    private let hermesGateway: HermesGatewayControlling
    private let codexModels: CodexModelSwitching
    private let codexRestarter: CodexApplicationRestarting
    private let extendedSettings: ExtendedSettingsStore
    private let screenBlackout: ScreenBlackoutService
    private let commandExecutor: TocodeCommandExecutor
    private let desktopCatalog: DesktopWindowCataloging
    private let desktopSwitcher: DesktopSpaceSwitching
    private let modelRelay: ModelRelayService
    private let automationRunner: ModelAutomationRunner
    private let actionDispatcher = KeyboardMappingActionDispatcher()
    private var activeModelMenu: NSMenu?
    private var activeModelParentItem: NSMenuItem?
    private var currentModelID: String?
    private var modelDescriptors: [String: CodexModelDescriptor] = [:]
    private var modelLoadGeneration = UUID()
    private var isSwitchingModel = false
    private var isCreatingModelRelayProvider = false
    private var relayBusyProviderIDs: Set<UUID> = []
    private var modifierPollingTimer: Timer?
    private var timerMenuRefreshTimer: Timer?
    private weak var liveTimerMenu: NSMenu?
    private weak var liveModelRelayStatusItem: NSMenuItem?
    private var liveTimerMenuItems: [UUID: NSMenuItem] = [:]
    private weak var liveModelMenuItem: NSMenuItem?
    private static let codexModelItemID = "tocode.extended.codexModel"
    private static let portableSettingsType =
        UTType(tag: "tocode", tagClass: .filenameExtension, conformingTo: .json) ?? .json

    init(
        shortcuts: GlobalShortcutService,
        trackpadShortcuts: TrackpadShortcutControlling,
        keyboardRemaps: KeyboardShortcutRemapControlling,
        spaceModifier: SpaceModifierControlling,
        mouseWheel: MouseWheelReverseService,
        dockAutohideRestrict: DockAutohideRestrictService = DockAutohideRestrictService(),
        macTimers: MacTimerControlling = MacTimerService(),
        shortcutPoster: TrackpadShortcutEventPosting = SystemTrackpadShortcutEventPoster(),
        launchAtLogin: LaunchAtLoginControlling = LaunchAtLoginService(),
        weChat: WeChatAssociationControlling,
        remoteControl: RemoteControlService,
        codex: CodexProjectService = CodexProjectService(),
        codexSync: CodexSyncSettingsStore = CodexSyncSettingsStore(),
        finderFollow: FinderFollowSettingsStore = FinderFollowSettingsStore(),
        terminalFollow: TerminalFollowSettingsStore = TerminalFollowSettingsStore(),
        hermesFollow: HermesFollowSettingsStore = HermesFollowSettingsStore(),
        hermesProjects: HermesProjectService = HermesProjectService(),
        hermesGateway: HermesGatewayControlling,
        codexModels: CodexModelSwitching = CodexModelSwitchService(),
        codexRestarter: CodexApplicationRestarting = CodexApplicationRestarter(),
        extendedSettings: ExtendedSettingsStore = ExtendedSettingsStore(),
        screenBlackout: ScreenBlackoutService? = nil,
        modelRelay: ModelRelayService,
        commandExecutor: TocodeCommandExecutor,
        desktopCatalog: DesktopWindowCataloging = SystemDesktopWindowCatalog(),
        desktopSwitcher: DesktopSpaceSwitching = SystemDesktopSpaceSwitcher()
    ) {
        self.shortcuts = shortcuts
        self.trackpadShortcuts = trackpadShortcuts
        self.keyboardRemaps = keyboardRemaps
        self.spaceModifier = spaceModifier
        self.mouseWheel = mouseWheel
        self.dockAutohideRestrict = dockAutohideRestrict
        self.macTimers = macTimers
        self.shortcutPoster = shortcutPoster
        self.launchAtLogin = launchAtLogin
        self.weChat = weChat
        self.remoteControl = remoteControl
        self.codex = codex
        self.codexSync = codexSync
        self.finderFollow = finderFollow
        self.terminalFollow = terminalFollow
        self.hermesFollow = hermesFollow
        self.hermesProjects = hermesProjects
        self.hermesGateway = hermesGateway
        self.codexModels = codexModels
        self.codexRestarter = codexRestarter
        self.extendedSettings = extendedSettings
        self.screenBlackout = screenBlackout ?? ScreenBlackoutService(overlay: ScreenBlackoutOverlay())
        self.modelRelay = modelRelay
        self.automationRunner = ModelAutomationRunner(
            lookup: { ModelAutomationStore().automation(id: $0) },
            readSelection: { await SystemSelectedTextReader().readSelectedText() },
            complete: { alias, prompt, text in
                try await modelRelay.completeAutomation(
                    modelAlias: alias,
                    systemPrompt: prompt,
                    userText: text
                )
            },
            copy: { ClipboardService().copy($0) },
            paste: { KeyboardEventSynthesizer().postCommandV() },
            notify: { title, body in
                ModelAutomationNotification.post(title: title, body: body)
            }
        )
        self.commandExecutor = commandExecutor
        self.desktopCatalog = desktopCatalog
        self.desktopSwitcher = desktopSwitcher
        let terminalWindows = DirectoryTerminalWindowStore()
        self.terminalWindows = terminalWindows
        self.terminalFrontWindow = SystemDirectoryTerminalFrontWindowReader()
        self.builder = MenuBuilder(terminalWindows: terminalWindows)
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
        modelRelay.didChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshModelRelayStatus()
            }
        }
        requestNotificationAuthorization()
    }

    @objc private func handleClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        switch StatusItemPrimaryClick.resolve(
            isRightClick: event.type == .rightMouseUp,
            tottiHeld: spaceModifier.isTottiHeld
        ) {
        case .actionMenu where event.type == .rightMouseUp:
            showActionMenu()
        case .desktopWindows where event.type == .leftMouseUp:
            showDesktopWindowMenu()
        case .directory where event.type == .leftMouseUp:
            showDirectoryMenu()
        default:
            break
        }
    }

    /// 按住 totti 的左键：列出各桌面及其窗口。不读取、不改写固定根。
    private func showDesktopWindowMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let entries = desktopCatalog.loadMenu() {
            for entry in entries {
                menu.addItem(makeDesktopEntry(entry))
            }
        }
        if menu.items.isEmpty {
            let unavailable = NSMenuItem(title: "无法读取桌面", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            menu.addItem(unavailable)
        }
        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func makeDesktopEntry(_ entry: DesktopMenuEntry) -> NSMenuItem {
        switch entry {
        case .display(let title, let spaces):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "display", accessibilityDescription: title)
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for space in spaces {
                submenu.addItem(makeDesktopSpaceItem(space))
            }
            item.submenu = submenu
            return item
        case .space(let space):
            return makeDesktopSpaceItem(space)
        }
    }

    private func makeDesktopSpaceItem(_ space: DesktopMenuSpace) -> NSMenuItem {
        if space.target.kind == .fullscreen {
            return makeFullscreenSpaceItem(space)
        }
        return makeDesktopFolderItem(space)
    }

    private func makeFullscreenSpaceItem(_ space: DesktopMenuSpace) -> NSMenuItem {
        let item = NSMenuItem(
            title: space.title,
            action: #selector(performDesktopCommand(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.state = space.isCurrent ? .on : .off
        item.representedObject = DesktopWindowCommandBox(.space(space.target))
        return item
    }

    private func makeDesktopFolderItem(_ space: DesktopMenuSpace) -> NSMenuItem {
        let item = NSMenuItem(title: space.title, action: nil, keyEquivalent: "")
        item.state = space.isCurrent ? .on : .off
        item.representedObject = DesktopWindowCommandBox(.space(space.target))
        let row = DesktopSpaceMenuRow(title: space.title, checked: space.isCurrent)
        let command = DesktopWindowCommand.space(space.target)
        row.onClick = { [weak self] in
            self?.runDesktopCommand(command)
        }
        item.view = row
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for window in space.windows {
            let child = NSMenuItem(
                title: window.title,
                action: #selector(performDesktopCommand(_:)),
                keyEquivalent: ""
            )
            child.target = self
            child.representedObject = DesktopWindowCommandBox(
                .window(window.target, windowID: window.windowID, pid: window.pid)
            )
            submenu.addItem(child)
        }
        item.submenu = submenu
        return item
    }

    @objc private func performDesktopCommand(_ sender: NSMenuItem) {
        guard let command = (sender.representedObject as? DesktopWindowCommandBox)?.command else { return }
        DispatchQueue.main.async { [weak self] in
            self?.runDesktopCommand(command)
        }
    }

    private func runDesktopCommand(_ command: DesktopWindowCommand) {
        let switched = desktopSwitcher.switchToSpace(command.spaceTarget)
        guard DesktopWindowActivation.shouldRaise(switched: switched, command: command) else {
            if !switched {
                notifyDesktopSwitch("无法切换桌面", "系统没有切到所选桌面。")
            }
            return
        }
        guard case .window(_, let windowID, let pid) = command else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            if !self.desktopSwitcher.raiseWindow(pid: pid, windowID: windowID) {
                self.notifyDesktopSwitch(
                    "无法把窗口带到前台",
                    "请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 Tocode。桌面已经切换。"
                )
            }
        }
    }

    private func notifyDesktopSwitch(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "tocode.desktop-window.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// 左键根目录解析：默认固定目录；访达/Codex/Hermes/终端跟随开启时才临时接管。
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
        let hermesRoot: String?
        if hermesFollow.followEnabled, frontmost == .hermes {
            hermesRoot = hermesProjects.resolveProject()?.rootPath
        } else {
            hermesRoot = nil
        }
        let terminalRoot: String?
        if terminalFollow.followEnabled, frontmost == .terminal, let front = terminalFrontWindow.frontWindow() {
            terminalRoot = DirectoryTerminalFollow.validatedPath(
                terminalWindows.path(matching: front),
                isDirectory: { fs.isExistingDirectory($0) }
            )
        } else {
            terminalRoot = nil
        }
        return DirectoryRootResolver.resolve(
            frontmost: frontmost,
            finderFollowEnabled: finderFollow.followEnabled,
            finderDirectory: finderDirectory,
            codexFollowEnabled: codexSync.syncEnabled,
            codexRoot: codexRoot,
            terminalFollowEnabled: terminalFollow.followEnabled,
            terminalRoot: terminalRoot,
            hermesFollowEnabled: hermesFollow.followEnabled,
            hermesRoot: hermesRoot,
            manualRoot: store.resolveRoot(isDirectory: { fs.isExistingDirectory($0) })
        )
    }

    /// 左键：弹出目录树（始终从当前根第一层）；根菜单含「历史」「配置」「终端」与「新增」。
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
            title: "终端跟随",
            enabled: terminalFollow.followEnabled,
            action: #selector(toggleTerminalFollow(_:))
        )
        addShortcutToggle(
            to: submenu,
            title: "codex跟随",
            enabled: codexSync.syncEnabled,
            action: #selector(toggleCodexProjectSync(_:))
        )
        addShortcutToggle(
            to: submenu,
            title: "hermes跟随",
            enabled: hermesFollow.followEnabled,
            action: #selector(toggleHermesFollow(_:))
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
                case .openURL:
                    symbolName = "link"
                case .automation:
                    symbolName = "wand.and.stars"
                }
                item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "已配置")
                item.toolTip = "\(mapping.source.displayName) → \(mapping.target.displayText)"
            }
        }
        keyboardItem.submenu = keyboardMenu

        let remoteButtonItem = inputMenu.addItem(withTitle: "遥控", action: nil, keyEquivalent: "")
        remoteButtonItem.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
        let remoteButtonMenu = NSMenu()
        remoteButtonMenu.autoenablesItems = false
        let addRemoteButton = remoteButtonMenu.addItem(
            withTitle: "新增",
            action: #selector(createRemoteButton),
            keyEquivalent: ""
        )
        addRemoteButton.target = self
        addRemoteButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新增")
        let savedRemoteButtons = RemoteButtonStore().all()
        if !savedRemoteButtons.isEmpty {
            remoteButtonMenu.addItem(.separator())
            for button in savedRemoteButtons {
                let item = remoteButtonMenu.addItem(
                    withTitle: button.name,
                    action: #selector(editRemoteButton(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = button.id.uuidString
                item.image = NSImage(
                    systemSymbolName: RemoteButtonIcons.symbol(for: button.icon),
                    accessibilityDescription: button.name
                )
            }
        }
        remoteButtonItem.submenu = remoteButtonMenu

        let remapKeyItem = inputMenu.addItem(withTitle: "改键", action: nil, keyEquivalent: "")
        remapKeyItem.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)
        let remapKeyMenu = NSMenu()
        remapKeyMenu.autoenablesItems = false
        addShortcutToggle(
            to: remapKeyMenu,
            title: "空格修饰键",
            enabled: spaceModifier.isEffective,
            action: #selector(toggleSpaceModifier(_:))
        )
        remapKeyItem.submenu = remapKeyMenu

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

        // 独立顶层「模型」：本地 OpenAI-compatible 中转站，始终显示。
        menu.addItem(makeModelRelayMenuItem())

        // AK 下直接列出 Codex 模型（AK 门控）。
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
            akItem.representedObject = Self.codexModelItemID
            let akMenu = NSMenu()
            akMenu.autoenablesItems = false
            akMenu.delegate = self
            addModelStatusItem("悬停后实时加载", to: akMenu)
            akItem.submenu = akMenu
            activeModelMenu = akMenu
            activeModelParentItem = akItem
            liveModelMenuItem = akItem
            if let state = try? codexModels.currentState() {
                currentModelID = state.liveModelID
                if !state.isConsistent {
                    akItem.toolTip = "Codex 实时配置与 CC Switch Provider 模板当前不一致"
                }
            }
        }

        let remoteItem = menu.addItem(withTitle: "应用", action: nil, keyEquivalent: "")
        remoteItem.image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
        let remoteMenu = NSMenu()
        remoteMenu.autoenablesItems = false
        let associate = remoteMenu.addItem(
            withTitle: "绑定应用",
            action: #selector(openRemoteAssociation),
            keyEquivalent: ""
        )
        associate.target = self
        ShortcutMenuAppearance.apply(to: associate, enabled: remoteControl.isAssociated)
        let gateway = remoteMenu.addItem(
            withTitle: HermesGatewayMenu.title,
            action: #selector(toggleHermesGateway),
            keyEquivalent: ""
        )
        gateway.target = self
        gateway.isEnabled = hermesGateway.isInstalled
        gateway.state = .off
        gateway.toolTip = HermesGatewayMenu.toolTip(
            phase: hermesGateway.phase,
            installed: hermesGateway.isInstalled
        )
        gateway.image = NSImage(
            systemSymbolName: HermesGatewayMenu.symbolName(phase: hermesGateway.phase),
            accessibilityDescription: HermesGatewayMenu.title
        )
        remoteItem.submenu = remoteMenu

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
        liveModelRelayStatusItem = nil
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

    /// 重置初始目录：把根文件夹设回现存默认目录并通知。
    @objc private func resetRoot() {
        let path = store.reset(isDirectory: { fs.isExistingDirectory($0) })
        notifyRootChanged(path)
    }

    /// 切换「hermes跟随」开关并更新勾选圆。
    @objc private func toggleHermesFollow(_ sender: NSMenuItem) {
        hermesFollow.followEnabled = !hermesFollow.followEnabled
        ShortcutMenuAppearance.apply(to: sender, enabled: hermesFollow.followEnabled)
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

    /// 切换「终端跟随」开关并更新勾选圆。
    @objc private func toggleTerminalFollow(_ sender: NSMenuItem) {
        terminalFollow.followEnabled = !terminalFollow.followEnabled
        ShortcutMenuAppearance.apply(to: sender, enabled: terminalFollow.followEnabled)
    }

    @objc private func toggleExtendedSettingAK(_ sender: NSMenuItem) {
        extendedSettings.akEnabled = !extendedSettings.akEnabled
        ShortcutMenuAppearance.apply(to: sender, enabled: extendedSettings.akEnabled)
    }

    private func makeModelRelayMenuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "模型", action: nil, keyEquivalent: "")
        root.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: nil)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let snapshot = modelRelay.snapshot()

        let status = menu.addItem(
            withTitle: "状态",
            action: #selector(showModelRelayStatus),
            keyEquivalent: ""
        )
        status.target = self
        status.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: nil)
        status.toolTip = "\(modelRelayStatusTitle()) · http://127.0.0.1:\(snapshot.port)/v1"
        liveModelRelayStatusItem = status

        let port = menu.addItem(
            withTitle: "端口：\(snapshot.port)…",
            action: #selector(changeModelRelayPort),
            keyEquivalent: ""
        )
        port.target = self
        port.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)

        if case .failed = modelRelay.runState {
            let restart = menu.addItem(
                withTitle: "重新启动",
                action: #selector(restartModelRelay),
                keyEquivalent: ""
            )
            restart.target = self
            restart.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        }

        menu.addItem(.separator())
        let providersItem = menu.addItem(withTitle: "厂家", action: nil, keyEquivalent: "")
        providersItem.image = NSImage(systemSymbolName: "building.2", accessibilityDescription: nil)
        let providersMenu = NSMenu()
        providersMenu.autoenablesItems = false
        let addProvider = providersMenu.addItem(
            withTitle: "新增",
            action: #selector(addModelRelayProvider),
            keyEquivalent: ""
        )
        addProvider.target = self
        addProvider.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addProvider.isEnabled = !isCreatingModelRelayProvider
        if !snapshot.providers.isEmpty {
            providersMenu.addItem(.separator())
        }
        for provider in snapshot.providers.sorted(by: {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }) {
            providersMenu.addItem(ModelRelayPrompts.providerMenuItem(
                provider,
                busy: relayBusyProviderIDs.contains(provider.id),
                target: self,
                action: #selector(manageModelRelayProvider(_:))
            ))
        }
        providersItem.submenu = providersMenu

        let keysItem = menu.addItem(withTitle: "密钥", action: nil, keyEquivalent: "")
        keysItem.image = NSImage(systemSymbolName: "key", accessibilityDescription: nil)
        let keysMenu = NSMenu()
        keysMenu.autoenablesItems = false
        let addKey = keysMenu.addItem(
            withTitle: "新增",
            action: #selector(addModelRelayLocalKey),
            keyEquivalent: ""
        )
        addKey.target = self
        addKey.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        if !snapshot.localKeys.isEmpty {
            keysMenu.addItem(.separator())
        }
        for key in snapshot.localKeys.sorted(by: {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }) {
            keysMenu.addItem(ModelRelayPrompts.localKeyMenuItem(
                key,
                target: self,
                action: #selector(accessModelRelayLocalKey(_:))
            ))
        }
        keysItem.submenu = keysMenu

        let automationsItem = menu.addItem(withTitle: "自动化", action: nil, keyEquivalent: "")
        automationsItem.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        let automationsMenu = NSMenu()
        automationsMenu.autoenablesItems = false
        let addAutomation = automationsMenu.addItem(
            withTitle: "新增",
            action: #selector(createModelAutomation),
            keyEquivalent: ""
        )
        addAutomation.target = self
        addAutomation.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        let savedAutomations = ModelAutomationStore().all().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if !savedAutomations.isEmpty {
            automationsMenu.addItem(.separator())
        }
        for automation in savedAutomations {
            let item = automationsMenu.addItem(
                withTitle: automation.name,
                action: #selector(editModelAutomation(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = automation.id.uuidString
            item.toolTip = automation.modelAlias
        }
        automationsItem.submenu = automationsMenu
        root.submenu = menu
        return root
    }

    private func modelRelayStatusTitle() -> String {
        let state = modelRelay.runState
        if case .running = state, modelRelay.router.availableAliases().isEmpty {
            return "\(state.menuText) · 无健康上游"
        }
        return state.menuText
    }

    private func refreshModelRelayStatus() {
        liveModelRelayStatusItem?.title = "状态"
        if let snapshotPort = Optional(modelRelay.snapshot().port) {
            liveModelRelayStatusItem?.toolTip =
                "\(modelRelayStatusTitle()) · http://127.0.0.1:\(snapshotPort)/v1"
        }
    }

    @objc private func showModelRelayStatus() {
        let snapshot = modelRelay.snapshot()
        ModelRelayStatusPanel.present(
            port: snapshot.port,
            runState: modelRelay.runState,
            providers: snapshot.providers,
            metrics: modelRelay.callMetrics
        )
    }

    @objc private func restartModelRelay() {
        modelRelay.stop()
        do {
            try modelRelay.start()
        } catch {
            ModelRelayPrompts.showError(error, title: "中转服务启动失败")
        }
    }

    @objc private func changeModelRelayPort() {
        let snapshot = modelRelay.snapshot()
        guard let port = ModelRelayPrompts.port(current: snapshot.port) else { return }
        modelRelay.updatePort(port) { result in
            if case .failure(let error) = result {
                ModelRelayPrompts.showError(error, title: "端口未修改，已恢复原监听")
            }
        }
    }

    @objc private func addModelRelayProvider() {
        guard !isCreatingModelRelayProvider else { return }
        isCreatingModelRelayProvider = true
        presentModelRelayProviderForm(providerID: nil)
    }

    private func presentModelRelayProviderForm(
        providerID: UUID?,
        draft: ModelRelayPrompts.ProviderDraft? = nil,
        tested: ModelRelayProviderConnectionTest? = nil,
        status: String? = nil
    ) {
        let existing = providerID.flatMap { id in
            modelRelay.snapshot().providers.first(where: { $0.id == id })
        }
        if providerID != nil, existing == nil {
            ModelRelayPrompts.showError(ModelRelayError.providerNotFound)
            return
        }
        switch ModelRelayPrompts.providerForm(
            existing: existing,
            draft: draft,
            tested: tested,
            status: status,
            performTest: { [weak self] nextDraft, completion in
                guard let self else { return }
                let baseURL: String
                do {
                    baseURL = try nextDraft.resolvedBaseURL()
                } catch {
                    completion(.failure(error))
                    return
                }
                if let providerID {
                    self.relayBusyProviderIDs.insert(providerID)
                }
                self.modelRelay.testProviderConnection(
                    providerID: providerID,
                    baseURL: baseURL,
                    candidateSecret: nextDraft.secret.isEmpty ? nil : nextDraft.secret
                ) { [weak self] result in
                    if let providerID {
                        self?.relayBusyProviderIDs.remove(providerID)
                    }
                    completion(result)
                }
            },
            performRefresh: providerID.map { id in
                { [weak self] completion in
                    guard let self else { return }
                    self.relayBusyProviderIDs.insert(id)
                    self.modelRelay.fetchModels(providerID: id) { [weak self] result in
                        self?.relayBusyProviderIDs.remove(id)
                        completion(result.map(\.count))
                    }
                }
            }
        ) {
        case .cancel:
            if providerID == nil {
                isCreatingModelRelayProvider = false
            }
            return
        case .delete(let nextDraft):
            guard let providerID,
                  let provider = modelRelay.snapshot().providers.first(where: { $0.id == providerID }) else {
                return
            }
            guard ModelRelayPrompts.confirm(
                title: "删除厂家“\(provider.name)”？",
                detail: "该厂家的模型目录和唯一上游 Key 都会删除。"
            ) else {
                presentModelRelayProviderForm(
                    providerID: providerID,
                    draft: nextDraft,
                    tested: tested,
                    status: status
                )
                return
            }
            do {
                try modelRelay.deleteProvider(id: providerID)
            } catch {
                ModelRelayPrompts.showError(error, title: "厂家未删除")
                presentModelRelayProviderForm(
                    providerID: providerID,
                    draft: nextDraft,
                    tested: tested,
                    status: error.localizedDescription
                )
            }
        case .save(let nextDraft, let latestTest):
            do {
                if let providerID {
                    try modelRelay.updateProvider(
                        id: providerID,
                        name: nextDraft.name,
                        using: nextDraft.requiresConnectionTest() ? latestTest : nil
                    )
                } else {
                    guard let latestTest else {
                        throw ModelRelayError.providerConnectionNotTested
                    }
                    try modelRelay.createProvider(name: nextDraft.name, using: latestTest)
                    isCreatingModelRelayProvider = false
                }
            } catch {
                presentModelRelayProviderForm(
                    providerID: providerID,
                    draft: nextDraft,
                    tested: latestTest,
                    status: error.localizedDescription
                )
            }
        }
    }

    @objc private func manageModelRelayProvider(_ sender: NSMenuItem) {
        guard let providerID = representedUUID(sender) else { return }
        presentModelRelayProviderForm(providerID: providerID)
    }

    @objc private func addModelRelayLocalKey() {
        guard let input = ModelRelayPrompts.localKey() else { return }
        do {
            _ = try modelRelay.createLocalKey(name: input.name, password: input.password)
            ModelRelayPrompts.showMessage(
                title: "本地 Key 已生成",
                detail: "点击该名称并输入查看密码，即可复制连接信息。"
            )
        } catch {
            ModelRelayPrompts.showError(error, title: "本地 Key 未生成")
        }
    }

    @objc private func accessModelRelayLocalKey(_ sender: NSMenuItem) {
        guard let id = representedUUID(sender),
              let record = modelRelay.snapshot().localKeys.first(where: { $0.id == id }),
              let action = ModelRelayPrompts.localKeyAction(name: record.name) else { return }
        do {
            switch action {
            case .copy(let password):
                clipboard.copy(try modelRelay.connectionBlock(localKeyID: id, password: password))
                ModelRelayPrompts.showMessage(
                    title: "连接信息已复制",
                    detail: "剪贴板包含 Base URL、API Key 和当前可用模型，请妥善保管。"
                )
            case .delete:
                try modelRelay.deleteLocalKey(id: id)
            }
        } catch {
            ModelRelayPrompts.showError(error, title: "查看密码校验失败")
        }
    }

    private func representedUUID(_ sender: NSMenuItem) -> UUID? {
        (sender.representedObject as? String).flatMap(UUID.init(uuidString:))
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

    @objc private func toggleHermesGateway() {
        hermesGateway.toggle()
    }

    @objc private func openRemoteAssociation() {
        remoteControl.startAssociation()
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
        switch ShortcutRecorderPrompt.prompt(
            for: gesture,
            existing: existing,
            automations: ModelAutomationStore().all()
        ) {
        case .save(let target):
            if target.emitsTotti {
                presentKeyboardMappingError(.tottiNotEmittable, title: "无法保存触控板快捷键")
            } else {
                _ = trackpadShortcuts.setBinding(target, for: gesture)
            }
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
                isEditing: isEditing,
                automations: ModelAutomationStore().all()
            ) {
            case .save(let candidate):
                switch keyboardRemaps.saveMapping(candidate) {
                case .success:
                    return
                case .failure(let error):
                    presentKeyboardMappingError(error, title: "无法保存键盘映射")
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

    @objc private func createRemoteButton() {
        presentRemoteButtonEditor(draft: RemoteButtonDraft(), isEditing: false)
    }

    @objc private func editRemoteButton(_ sender: NSMenuItem) {
        guard
            let rawID = sender.representedObject as? String,
            let id = UUID(uuidString: rawID),
            let button = RemoteButtonStore().all().first(where: { $0.id == id })
        else {
            return
        }
        presentRemoteButtonEditor(draft: RemoteButtonDraft(button: button), isEditing: true)
    }

    private func presentRemoteButtonEditor(draft initialDraft: RemoteButtonDraft, isEditing: Bool) {
        shortcuts.setInputCaptureSuspended(true)
        keyboardRemaps.setInputCaptureSuspended(true)
        defer {
            keyboardRemaps.setInputCaptureSuspended(false)
            shortcuts.setInputCaptureSuspended(false)
        }
        let store = RemoteButtonStore()
        var draft = initialDraft
        while true {
            switch RemoteButtonPrompt.prompt(
                draft: draft,
                isEditing: isEditing,
                automations: ModelAutomationStore().all()
            ) {
            case .save(let candidate):
                switch store.save(candidate) {
                case .success:
                    return
                case .failure(let error):
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "无法保存遥控按钮"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                    draft = candidate
                }
            case .delete:
                if let id = draft.id {
                    store.delete(id: id)
                }
                return
            case .cancel:
                return
            }
        }
    }

    func performRemoteButton(_ button: RemoteButton) -> (Bool, String) {
        guard case .mapped(let target) = button.target else {
            return (false, "无法执行")
        }
        switch target.remapStep() {
        case .emit(let shortcut):
            if shortcutPoster.post(shortcut) {
                return (true, "已执行")
            }
            return (false, "目标快捷键未能发送。")
        case .invoke(let action):
            performMappedAction(action)
            return (true, "已执行")
        case .openURL(let raw):
            if MappedURLLaunch.openStored(raw) {
                return (true, "已执行")
            }
            return (false, "系统没有打开该网址。")
        case .runAutomation(let id):
            runModelAutomation(id)
            return (true, "已执行")
        case .emitDown, .emitRepeat, .emitUp, .pass, .suppress:
            return (false, "无法执行")
        }
    }

    @objc private func toggleSpaceModifier(_ sender: NSMenuItem) {
        _ = spaceModifier.setEnabled(!spaceModifier.isEffective)
        ShortcutMenuAppearance.apply(to: sender, enabled: spaceModifier.isEffective)
    }

    private func presentKeyboardMappingError(
        _ error: KeyboardShortcutMappingValidationError,
        title: String
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
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
            switch MacTimerPrompt.prompt(
                draft: draft,
                mode: mode,
                automations: ModelAutomationStore().all()
            ) {
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

    func runModelAutomation(_ id: UUID) {
        automationRunner.run(id: id)
    }

    @objc private func createModelAutomation() {
        presentModelAutomationEditor(draft: ModelAutomationDraft(), isEditing: false)
    }

    @objc private func editModelAutomation(_ sender: NSMenuItem) {
        guard
            let rawID = sender.representedObject as? String,
            let id = UUID(uuidString: rawID),
            let automation = ModelAutomationStore().automation(id: id)
        else {
            return
        }
        presentModelAutomationEditor(
            draft: ModelAutomationDraft(automation: automation),
            isEditing: true
        )
    }

    private func presentModelAutomationEditor(
        draft initialDraft: ModelAutomationDraft,
        isEditing: Bool
    ) {
        var draft = initialDraft
        let store = ModelAutomationStore()
        while true {
            let aliases = modelRelay.router.availableAliases()
            switch ModelAutomationPrompt.prompt(
                draft: draft,
                isEditing: isEditing,
                modelAliases: aliases
            ) {
            case .save(let candidate):
                switch store.save(candidate, availableAliases: Set(aliases)) {
                case .success:
                    return
                case .failure(let error):
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "无法保存自动化"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                    draft = candidate
                }
            case .delete:
                if let id = draft.id {
                    store.delete(id: id)
                }
                return
            case .cancel:
                return
            }
        }
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
        case .openURL(let raw):
            if !MappedURLLaunch.openStored(raw) {
                notifyMappedAction("定时器执行失败", "系统没有打开该网址。任务已保留。")
            }
        case .emitDown, .emitRepeat, .emitUp, .pass, .suppress:
            break
        case .runAutomation(let id):
            runModelAutomation(id)
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

/// 桌面夹这一行可点击。带 submenu 的菜单项本身不会触发 action，所以用行视图接收点击，悬停仍展开窗口。
private final class DesktopSpaceMenuRow: NSView {
    var onClick: (() -> Void)?
    private let title: String
    private let checked: Bool

    init(title: String, checked: Bool) {
        self.title = title
        self.checked = checked
        super.init(frame: .zero)
        let font = NSFont.menuFont(ofSize: 0)
        let width = ceil((title as NSString).size(withAttributes: [.font: font]).width) + 64
        frame = NSRect(x: 0, y: 0, width: max(width, 160), height: 24)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = enclosingMenuItem?.isHighlighted ?? false
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            bounds.fill()
        }
        let color: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        let font = NSFont.menuFont(ofSize: 0)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        if checked {
            ("✓" as NSString).draw(in: NSRect(x: 6, y: 3, width: 16, height: bounds.height - 4), withAttributes: attributes)
        }
        (title as NSString).draw(
            in: NSRect(x: 24, y: 3, width: max(0, bounds.width - 52), height: bounds.height - 4),
            withAttributes: attributes
        )
        let chevron = NSBezierPath()
        let tipX = bounds.width - 14
        let midY = bounds.midY
        chevron.move(to: NSPoint(x: tipX - 4, y: midY - 4))
        chevron.line(to: NSPoint(x: tipX, y: midY))
        chevron.line(to: NSPoint(x: tipX - 4, y: midY + 4))
        chevron.lineWidth = 1.4
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        color.setStroke()
        chevron.stroke()
    }

    override func mouseUp(with event: NSEvent) {
        enclosingMenuItem?.menu?.cancelTracking()
        let click = onClick
        DispatchQueue.main.async {
            click?()
        }
    }
}
