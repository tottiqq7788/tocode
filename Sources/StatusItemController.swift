import AppKit
import UniformTypeIdentifiers
import UserNotifications

/// 两个菜单栏图标：文件夹负责路径和书签，窗口图标负责桌面和一次性动作。
@MainActor
final class StatusItemController: NSObject, SettingsHosting {
    private let folderItem: NSStatusItem
    private let windowsItem: NSStatusItem
    private var settingsWindow: SettingsWindowController?
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
    private let bookmarkSync: BookmarkSyncService
    private let shortcutPoster: TrackpadShortcutEventPosting
    private let launchAtLogin: LaunchAtLoginControlling
    private let weChat: WeChatAssociationControlling
    private let remoteControl: RemoteControlService
    private let codex: CodexProjectService
    private let codexSync: CodexSyncSettingsStore
    private let finderFollow: FinderFollowSettingsStore
    private let statusBarIcons = StatusBarIconSettingsStore()
    private let terminalFollow: TerminalFollowSettingsStore
    private let hermesFollow: HermesFollowSettingsStore
    private let hermesProjects: HermesProjectService
    private let hermesGateway: HermesGatewayControlling
    private let screenBlackout: ScreenBlackoutService
    private let commandExecutor: TocodeCommandExecutor
    private let desktopCatalog: DesktopWindowCataloging
    private let desktopSwitcher: DesktopSpaceSwitching
    private let modelRelay: ModelRelayService
    private let automationRunner: ModelAutomationRunner
    private let actionDispatcher = KeyboardMappingActionDispatcher()
    private var isCreatingModelRelayProvider = false
    private var relayBusyProviderIDs: Set<UUID> = []
    private var modifierPollingTimer: Timer?
    private var timerMenuRefreshTimer: Timer?
    private weak var liveTimerMenu: NSMenu?
    private weak var liveModelRelayStatusItem: NSMenuItem?
    private var liveTimerMenuItems: [UUID: NSMenuItem] = [:]
    /// 「拓展安装」子菜单 delegate（NSMenu.delegate 为 weak，须强引用）。
    private var bookmarkInstallMenuDelegate: BookmarkExtensionInstallMenuDelegate?
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
        bookmarkSync: BookmarkSyncService,
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
        self.bookmarkSync = bookmarkSync
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
        folderItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        windowsItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
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
        actionDispatcher.dismissBlackout = { [weak self] in
            self?.screenBlackout.dismiss()
        }
        actionDispatcher.toggleDockAutohideRestrict = { [weak self] in
            guard let self else { return "不可用" }
            let next = !self.dockAutohideRestrict.isEffective
            _ = self.dockAutohideRestrict.setEnabled(next)
            return self.dockAutohideRestrict.isEffective ? "已开启" : "已关闭"
        }
        actionDispatcher.lockScreen = { ScreenLock.lock() }
        macTimers.onChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshLiveTimerMenuItems()
            }
        }
        installStatusItem(
            folderItem,
            slot: .folder,
            help: "路径与书签",
            autosaveName: "tocode.folder"
        )
        installStatusItem(
            windowsItem,
            slot: .windows,
            help: "窗口与动作",
            autosaveName: "tocode.windows"
        )
        modelRelay.didChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshModelRelayStatus()
            }
        }
        requestNotificationAuthorization()
    }

    func showSettings(page: SettingsPage = .path, timerID: UUID? = nil) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(host: self)
        }
        settingsWindow?.reveal(page: page, timerID: timerID)
    }

    private func installStatusItem(
        _ item: NSStatusItem,
        slot: StatusBarIconSlot,
        help: String,
        autosaveName: String
    ) {
        item.autosaveName = autosaveName
        applyStatusBarIcon(item, slot: slot, help: help)
    }

    private func applyStatusBarIcon(_ item: NSStatusItem, slot: StatusBarIconSlot, help: String) {
        item.isVisible = statusBarIcons.isVisible(slot)
        guard let button = item.button else { return }
        button.image = NSImage(
            systemSymbolName: statusBarIcons.symbol(for: slot),
            accessibilityDescription: help
        )
        button.toolTip = help
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        let button = (sender as? NSStatusBarButton) ?? folderItem.button
        guard let button else { return }
        let slot: StatusItemSlot = button === windowsItem.button ? .windows : .folder
        let isRight = event.type == .rightMouseUp
        switch StatusItemPrimaryClick.resolve(slot: slot, isRightClick: isRight) {
        case .directory:
            showDirectoryMenu(on: button)
        case .bookmarks:
            showBookmarkMenu(on: button)
        case .desktopWindows:
            showDesktopWindowMenu(on: button)
        case .actions:
            showActionPalette(on: button)
        }
    }

    /// 窗口图标左键：列出各桌面及其窗口。不读取、不改写固定根。
    private func showDesktopWindowMenu(on button: NSStatusBarButton) {
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
        popUp(menu, on: button)
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

    /// 文件夹图标左键：弹出目录树。根菜单含「历史」「终端」与「新增」，不含配置。
    /// Shift 连续多选尽量保持同一菜单；若系统仍关闭则立刻再弹同一菜单。
    private func showDirectoryMenu(on button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let root = resolveDirectoryRoot()
        builder.makeRootConfigItem = nil
        builder.fillRoot(menu, with: root, includeHidden: visibility.currentShowAllFiles())

        startModifierPolling()
        builder.resetMultiCopySession()

        repeat {
            builder.beginTracking(rootMenu: menu)
            popUp(menu, on: button)
            builder.endTracking()
        } while builder.consumeSameMenuRepopRequest()

        builder.resetMultiCopySession()
        stopModifierPolling()
    }

    private func showBookmarkMenu(on button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        BookmarkMenuBuilder.fill(
            menu,
            snapshot: bookmarkSync.snapshot,
            target: self,
            action: #selector(openBookmarkMenuItem(_:))
        )
        popUp(menu, on: button)
    }

    @objc private func openBookmarkMenuItem(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            let url = URL(string: raw),
            url.scheme != nil
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// 窗口图标右键：只执行，不编辑配置。
    private func showActionPalette(on button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let blackout = menu.addItem(
            withTitle: "临时黑屏",
            action: #selector(activateScreenBlackout),
            keyEquivalent: ""
        )
        blackout.target = self
        blackout.image = NSImage(systemSymbolName: "display.trianglebadge.exclamationmark", accessibilityDescription: nil)

        let lock = menu.addItem(
            withTitle: "锁定屏幕",
            action: #selector(lockScreenFromMenu),
            keyEquivalent: ""
        )
        lock.target = self
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)

        let weChatLocation = menu.addItem(
            withTitle: "微信文件位置",
            action: #selector(openWeChatLocation),
            keyEquivalent: ""
        )
        weChatLocation.target = self
        weChatLocation.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)

        let openRoot = menu.addItem(
            withTitle: "在访达打开根目录",
            action: #selector(openFinderAtRoot),
            keyEquivalent: ""
        )
        openRoot.target = self
        openRoot.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)

        let copy = menu.addItem(
            withTitle: "复制访达选中路径",
            action: #selector(copyFinderSelectedPath),
            keyEquivalent: ""
        )
        copy.target = self
        copy.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)

        menu.addItem(.separator())
        liveTimerMenuItems.removeAll()
        let now = Date()
        let running = macTimers.timers.filter(\.isRunning)
        if running.isEmpty {
            let none = menu.addItem(withTitle: "没有正在运行的定时器", action: nil, keyEquivalent: "")
            none.isEnabled = false
        } else {
            for timer in running {
                let item = menu.addItem(
                    withTitle: MacTimerRemaining.menuTitle(
                        name: timer.name,
                        fireAt: timer.fireAt,
                        now: now
                    ),
                    action: #selector(openTimerInSettings(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = timer.id.uuidString
                item.toolTip = timer.target.displayText
                liveTimerMenuItems[timer.id] = item
            }
        }
        startTimerMenuRefresh()
        popUp(menu, on: button)
        stopTimerMenuRefresh()
        liveTimerMenu = nil
        liveTimerMenuItems.removeAll()
    }

    @objc private func lockScreenFromMenu() {
        if !ScreenLock.lock() {
            notifyMappedAction("无法锁定屏幕", "系统没有接受锁定请求。")
        }
    }

    @objc private func openTimerInSettings(_ sender: NSMenuItem) {
        let id = (sender.representedObject as? String).flatMap(UUID.init(uuidString:))
        showSettings(page: .tools, timerID: id)
    }

    private func popUp(_ menu: NSMenu, on button: NSStatusBarButton) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
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
            _ = try modelRelay.createLocalKey(name: input.name)
            ModelRelayPrompts.showMessage(
                title: "本地 Key 已生成",
                detail: "点击该名称并通过设备验证后，即可复制连接信息。"
            )
        } catch {
            ModelRelayPrompts.showError(error, title: "本地 Key 未生成")
        }
    }

    @objc private func accessModelRelayLocalKey(_ sender: NSMenuItem) {
        guard let id = representedUUID(sender),
              let record = modelRelay.snapshot().localKeys.first(where: { $0.id == id }) else { return }
        let needsMigration = modelRelay.localKeyNeedsMigration(id)
        guard let action = ModelRelayPrompts.localKeyAction(
            name: record.name,
            needsMigration: needsMigration
        ) else { return }
        Task { @MainActor in
            do {
                switch action {
                case .copy:
                    try await DeviceOwnerAuth.evaluate(reason: "验证后复制本地中转连接信息")
                    clipboard.copy(try modelRelay.connectionBlock(localKeyID: id))
                    ModelRelayPrompts.showMessage(
                        title: "连接信息已复制",
                        detail: "剪贴板包含 Base URL、API Key 和当前可用模型，请妥善保管。"
                    )
                case .migrate(let password):
                    clipboard.copy(try modelRelay.connectionBlock(localKeyID: id, password: password))
                    ModelRelayPrompts.showMessage(
                        title: "已迁移并复制",
                        detail: "密钥已迁入钥匙串。之后复制只需设备验证。"
                    )
                case .delete:
                    try await DeviceOwnerAuth.evaluate(reason: "验证后删除本地中转 Key")
                    try modelRelay.deleteLocalKey(id: id)
                }
            } catch {
                ModelRelayPrompts.showError(error, title: "本地 Key 操作失败")
            }
        }
    }

    private func representedUUID(_ sender: NSMenuItem) -> UUID? {
        (sender.representedObject as? String).flatMap(UUID.init(uuidString:))
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
        alert.informativeText = "将整段替换键盘映射、触控板轻点、快捷键开关与滚轮设置，且不可自动撤销。根目录、开机自启、微信与密钥不受影响。"
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

    @objc private func manageBindingKey() {
        Task { @MainActor in
            await self.presentBindingKeyManagement()
        }
    }

    @MainActor
    private func presentBindingKeyManagement() async {
        if remoteControl.hasBindingKey {
            do {
                try await DeviceOwnerAuth.evaluate(reason: "验证后可查看或管理绑定密钥")
                let secret = try remoteControl.revealBindingKey()
                switch BindingKeyPrompt.manage(hasSecret: true, revealed: secret) {
                case .set(let next):
                    try remoteControl.setBindingKey(next)
                case .clear:
                    try remoteControl.clearBindingKey()
                case .cancel:
                    break
                }
            } catch {
                ModelRelayPrompts.showError(error, title: "绑定密钥")
            }
            return
        }
        switch BindingKeyPrompt.manage(hasSecret: false, revealed: nil) {
        case .set(let secret):
            do {
                try remoteControl.setBindingKey(secret)
            } catch {
                ModelRelayPrompts.showError(error, title: "绑定密钥未保存")
            }
        case .clear, .cancel:
            break
        }
    }

    @objc private func openRemoteAssociation() {
        guard remoteControl.hasBindingKey else {
            let alert = NSAlert()
            alert.messageText = "请先设置绑定密钥"
            alert.informativeText = "在「应用 → 绑定密钥」中设置后，才能生成绑定二维码。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        remoteControl.startAssociation()
    }

    @objc private func openDiagnosticLogs() {
        DiagnosticLog.shared.openInFinder()
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

    @objc private func configureBookmarkRemoteSync() {
        Task { @MainActor in
            let action = await BookmarkSyncPrompt.present(
                hasKey: bookmarkSync.hasRemoteKey,
                isEnabled: bookmarkSync.isRemoteEnabled,
                revealKey: { try self.bookmarkSync.loadRemoteKeyPlaintext() }
            )
            do {
                switch action {
                case .save(let secret, let enable):
                    try bookmarkSync.saveRemoteKey(secret, enable: enable)
                case .setEnabled(let enabled):
                    bookmarkSync.setRemoteEnabled(enabled)
                case .delete:
                    try bookmarkSync.deleteRemoteKey()
                case .cancel:
                    break
                }
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "远程同步失败"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
    }

    @objc private func openBookmarkSyncLog() {
        BookmarkSyncLogWindow.present(log: bookmarkSync.activityLog)
    }

    @objc private func runBookmarkBackupNow() {
        Task { @MainActor in
            switch await bookmarkSync.backupNowForCLI() {
            case .success(let pack):
                let alert = NSAlert()
                alert.messageText = "日备完成"
                alert.informativeText = "已写入 \(pack.slots.count) 个槽位（最多 \(BookmarkBackupPack.maxSlots) 日）。"
                alert.addButton(withTitle: "好")
                alert.runModal()
            case .failure(let error):
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "日备失败"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
    }

    @objc private func restoreBookmarkBackup(_ sender: NSMenuItem) {
        guard let day = sender.representedObject as? String else { return }
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "从 \(day) 还原书签？"
        confirm.informativeText = "将用该日备份整本覆盖正式账本，并写回已连接浏览器。此操作不可撤销；还原前建议先「立即备份」。"
        confirm.addButton(withTitle: "还原")
        confirm.addButton(withTitle: "取消")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            switch await bookmarkSync.restoreBackupForCLI(day: day) {
            case .success(let snapshot):
                let alert = NSAlert()
                alert.messageText = "已还原"
                alert.informativeText = "正式账本现为 \(snapshot.entries.count) 条（来自 \(day)）。"
                alert.addButton(withTitle: "好")
                alert.runModal()
            case .failure(let error):
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "还原失败"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
    }

    @objc private func installBookmarkExtension(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let browser = BookmarkBrowser(rawValue: raw) else {
            return
        }
        BookmarkExtensionInstall.install(
            browser: browser,
            connectedKeys: bookmarkSync.connectedBrowserKeys
        )
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

extension StatusItemController {
    var settingsRootPath: String { store.resolveRoot(isDirectory: { fs.isExistingDirectory($0) }) }
    var settingsFinderFollow: Bool { finderFollow.followEnabled }
    var settingsTerminalFollow: Bool { terminalFollow.followEnabled }
    var settingsCodexFollow: Bool { codexSync.syncEnabled }
    var settingsHermesFollow: Bool { hermesFollow.followEnabled }
    var settingsShowHidden: Bool { visibility.currentShowAllFiles() }
    var settingsFinderMove: Bool { shortcuts.isFinderMoveEffective }
    var settingsFinderCommandQ: Bool { shortcuts.isFinderCommandQEffective }
    var settingsDoubleCommandQ: Bool { shortcuts.isDoubleCommandQEffective }
    var settingsVerticalWheel: Bool { mouseWheel.isVerticalEffective }
    var settingsHorizontalWheel: Bool { mouseWheel.isHorizontalEffective }
    var settingsSpaceModifier: Bool { spaceModifier.isEffective }
    var settingsDockRestrict: Bool { dockAutohideRestrict.isEffective }
    var settingsFolderIconVisible: Bool { statusBarIcons.isVisible(.folder) }
    var settingsWindowsIconVisible: Bool { statusBarIcons.isVisible(.windows) }
    var settingsFolderIconSymbol: String { statusBarIcons.symbol(for: .folder) }
    var settingsWindowsIconSymbol: String { statusBarIcons.symbol(for: .windows) }
    var settingsLaunchAtLogin: Bool { launchAtLogin.isEnabled }
    var settingsHermesInstalled: Bool { hermesGateway.isInstalled }
    var settingsHermesGatewayOn: Bool { hermesGateway.phase != .off }
    var settingsHermesGatewayDetail: String {
        HermesGatewayMenu.toolTip(phase: hermesGateway.phase, installed: hermesGateway.isInstalled)
    }
    var settingsBindingKeySet: Bool { remoteControl.hasBindingKey }
    var settingsAppAssociated: Bool { remoteControl.isAssociated }
    var settingsWeChatBound: Bool { weChat.isBound }
    var settingsModelSummary: String {
        let port = modelRelay.snapshot().port
        return "\(modelRelayStatusTitle()) · http://127.0.0.1:\(port)/v1"
    }
    var settingsModelFailed: Bool {
        if case .failed = modelRelay.runState { return true }
        return false
    }
    var settingsKeyboardMappings: [SettingsLabeledID] {
        keyboardRemaps.mappings.map {
            SettingsLabeledID(
                id: $0.id,
                title: $0.name,
                detail: "\($0.source.displayName) → \($0.target.displayText)"
            )
        }
    }
    var settingsTrackpadRows: [(gesture: TrackpadTapGesture, detail: String)] {
        TrackpadTapGesture.allCases.map { gesture in
            (gesture, trackpadShortcuts.binding(for: gesture)?.displayText ?? "")
        }
    }
    var settingsRemoteButtons: [SettingsLabeledID] {
        RemoteButtonStore().all().map {
            SettingsLabeledID(id: $0.id, title: $0.name, detail: remoteButtonDetail($0.target))
        }
    }
    var settingsTimers: [SettingsLabeledID] {
        let now = Date()
        return macTimers.timers.map {
            SettingsLabeledID(
                id: $0.id,
                title: MacTimerRemaining.menuTitle(name: $0.name, fireAt: $0.fireAt, now: now),
                detail: $0.target.displayText
            )
        }
    }
    var settingsProviders: [SettingsLabeledID] {
        modelRelay.snapshot().providers.map {
            SettingsLabeledID(id: $0.id, title: $0.name, detail: $0.baseURL)
        }
    }
    var settingsLocalKeys: [SettingsLabeledID] {
        modelRelay.snapshot().localKeys.map {
            SettingsLabeledID(id: $0.id, title: $0.name, detail: "")
        }
    }
    var settingsAutomations: [SettingsLabeledID] {
        ModelAutomationStore().all().map {
            SettingsLabeledID(id: $0.id, title: $0.name, detail: $0.modelAlias)
        }
    }
    var settingsBookmarkBackups: [String] {
        bookmarkSync.backupListPayload().compactMap { $0["day"] as? String }
    }
    var settingsBookmarkBrowsers: [(browser: BookmarkBrowser, online: Bool)] {
        BookmarkBrowser.allCases.map { browser in
            let online = bookmarkSync.connectedBrowserKeys.contains { $0.hasPrefix("\(browser.rawValue):") }
            return (browser, online)
        }
    }

    func settingsSetFinderFollow(_ on: Bool) { finderFollow.followEnabled = on }
    func settingsSetTerminalFollow(_ on: Bool) { terminalFollow.followEnabled = on }
    func settingsSetCodexFollow(_ on: Bool) { codexSync.syncEnabled = on }
    func settingsSetHermesFollow(_ on: Bool) { hermesFollow.followEnabled = on }
    func settingsSetShowHidden(_ on: Bool) {
        guard on != visibility.currentShowAllFiles() else { return }
        _ = visibility.setShowAllFiles(on)
    }
    func settingsSetFinderMove(_ on: Bool) { _ = shortcuts.setFinderMoveEnabled(on) }
    func settingsSetFinderCommandQ(_ on: Bool) { _ = shortcuts.setFinderCommandQEnabled(on) }
    func settingsSetDoubleCommandQ(_ on: Bool) { _ = shortcuts.setDoubleCommandQEnabled(on) }
    func settingsSetVerticalWheel(_ on: Bool) { _ = mouseWheel.setVerticalEnabled(on) }
    func settingsSetHorizontalWheel(_ on: Bool) { _ = mouseWheel.setHorizontalEnabled(on) }
    func settingsSetSpaceModifier(_ on: Bool) { _ = spaceModifier.setEnabled(on) }
    func settingsSetDockRestrict(_ on: Bool) { _ = dockAutohideRestrict.setEnabled(on) }
    func settingsSetFolderIconVisible(_ on: Bool) {
        statusBarIcons.setVisible(on, slot: .folder)
        applyStatusBarIcon(folderItem, slot: .folder, help: "路径与书签")
    }
    func settingsSetWindowsIconVisible(_ on: Bool) {
        statusBarIcons.setVisible(on, slot: .windows)
        applyStatusBarIcon(windowsItem, slot: .windows, help: "窗口与动作")
    }
    func settingsSetFolderIconSymbol(_ symbol: String) {
        statusBarIcons.setSymbol(symbol, slot: .folder)
        applyStatusBarIcon(folderItem, slot: .folder, help: "路径与书签")
    }
    func settingsSetWindowsIconSymbol(_ symbol: String) {
        statusBarIcons.setSymbol(symbol, slot: .windows)
        applyStatusBarIcon(windowsItem, slot: .windows, help: "窗口与动作")
    }
    func settingsSetLaunchAtLogin(_ on: Bool) {
        guard on != launchAtLogin.isEnabled else { return }
        if case .failure(let error) = launchAtLogin.setEnabled(on) {
            notifyLaunchAtLoginFailure(error)
        }
    }
    func settingsSetHermesGateway(_ on: Bool) {
        let running = hermesGateway.phase != .off
        guard on != running else { return }
        hermesGateway.toggle()
    }

    func settingsChooseRoot() { chooseRoot() }
    func settingsReadClipboard() { readClipboard() }
    func settingsResetRoot() { resetRoot() }
    func settingsCreateKeyboard() { createKeyboardMapping() }
    func settingsEditKeyboard(id: UUID) { editKeyboardMapping(menuSender(id.uuidString)) }
    func settingsEditTrackpad(_ gesture: TrackpadTapGesture) {
        configureTrackpadShortcut(menuSender(gesture.rawValue))
    }
    func settingsCreateRemoteButton() { createRemoteButton() }
    func settingsEditRemoteButton(id: UUID) { editRemoteButton(menuSender(id.uuidString)) }
    func settingsCreateTimer() { createMacTimer() }
    func settingsEditTimer(id: UUID) { editMacTimer(menuSender(id.uuidString)) }
    func settingsOpenBookmarkLog() { openBookmarkSyncLog() }
    func settingsConfigureBookmarkRemote() { configureBookmarkRemoteSync() }
    func settingsBackupBookmarksNow() { runBookmarkBackupNow() }
    func settingsRestoreBookmark(day: String) { restoreBookmarkBackup(menuSender(day)) }
    func settingsInstallBookmark(_ browser: BookmarkBrowser) {
        installBookmarkExtension(menuSender(browser.rawValue))
    }
    func settingsShowModelStatus() { showModelRelayStatus() }
    func settingsChangeModelPort() { changeModelRelayPort() }
    func settingsRestartModel() { restartModelRelay() }
    func settingsAddProvider() { addModelRelayProvider() }
    func settingsEditProvider(id: UUID) { manageModelRelayProvider(menuSender(id.uuidString)) }
    func settingsAccessLocalKey(id: UUID) { accessModelRelayLocalKey(menuSender(id.uuidString)) }
    func settingsAddLocalKey() { addModelRelayLocalKey() }
    func settingsCreateAutomation() { createModelAutomation() }
    func settingsEditAutomation(id: UUID) { editModelAutomation(menuSender(id.uuidString)) }
    func settingsManageBindingKey() { manageBindingKey() }
    func settingsOpenRemoteAssociation() { openRemoteAssociation() }
    func settingsOpenDiagnostics() { openDiagnosticLogs() }
    func settingsBindWeChat() { bindWeChat() }
    func settingsOpenWeChatLocation() { openWeChatLocation() }
    func settingsExport() { exportPortableSettings() }
    func settingsImport() { importPortableSettings() }
    func settingsShowManual() { showUserManual() }
    func settingsQuit() { NSApp.terminate(nil) }

    private func menuSender(_ value: Any) -> NSMenuItem {
        let item = NSMenuItem()
        item.representedObject = value
        return item
    }

    private func remoteButtonDetail(_ target: RemoteButtonTarget) -> String {
        switch target {
        case .mapped(let mapped):
            return mapped.displayText
        case .status:
            return "设备状态"
        case .dismissBlackout:
            return "取消黑屏"
        case .lock:
            return "锁定屏幕"
        }
    }
}
