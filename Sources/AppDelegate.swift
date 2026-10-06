import AppKit

@MainActor
private final class UnboundWeChat: WeChatAssociationControlling {
    var isBound: Bool { false }
    func startBinding() {}
    func startBoundListener() {}
    func stop() {}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var shortcuts: GlobalShortcutService?
    private var trackpadShortcuts: TrackpadShortcutService?
    private var keyboardRemaps: KeyboardShortcutRemapService?
    private var mouseWheel: MouseWheelReverseService?
    private var dockAutohideRestrict: DockAutohideRestrictService?
    private var macTimers: MacTimerService?
    private var weChat: WeChatAssociationService?
    private var controller: StatusItemController?
    private var commandExecutor: TocodeCommandExecutor?
    private var ipcServer: TocodeIPCServer?
    private var modelRelay: ModelRelayService?
    private var togent: TogentService?
    private var isPreparingTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        TocodePreferences.migrateIfNeeded()
        let service = GlobalShortcutService()
        service.applySavedSettings()
        shortcuts = service
        let trackpad = TrackpadShortcutService()
        trackpad.applySavedSettings()
        trackpadShortcuts = trackpad
        let keyboardRemaps = KeyboardShortcutRemapService()
        service.setExternalEventBypass { [weak keyboardRemaps] type, event in
            keyboardRemaps?.claims(type: type, event: event) ?? false
        }
        keyboardRemaps.applySavedSettings()
        self.keyboardRemaps = keyboardRemaps
        let wheel = MouseWheelReverseService()
        wheel.applySavedSettings()
        mouseWheel = wheel
        let dockRestrict = DockAutohideRestrictService()
        dockRestrict.applySavedSettings()
        dockAutohideRestrict = dockRestrict
        let macTimers = MacTimerService()
        self.macTimers = macTimers

        let blackout = ScreenBlackoutService(overlay: ScreenBlackoutOverlay())

        // 先启动 IPC，避免微信 Keychain 初始化阻塞命令入口。
        let executor = TocodeCommandExecutor(
            mouseWheel: wheel,
            shortcuts: service,
            codexModels: CodexModelSwitchService(),
            weChat: UnboundWeChat(),
            screenBlackout: blackout
        )
        commandExecutor = executor

        let server = TocodeIPCServer(executor: executor)
        do {
            try server.start()
            ipcServer = server
        } catch {
            NSLog("Tocode IPC server 启动失败: %@", error.localizedDescription)
        }

        // 必须先于模型 Relay 初始化执行；Relay 读取钥匙串时首次授权可能阻塞主线程。
        do {
            let migrated = try WeChatArchiveMigration().runIfNeeded()
            NSLog(
                "Tocode 旧微信归档迁移检查完成: %@",
                migrated ? "已执行" : "已完成，无需重复执行"
            )
        } catch {
            NSLog("Tocode 旧微信归档删除失败: %@", error.localizedDescription)
            UserNotificationWeChatNotifier().notify(
                title: "旧微信归档删除失败",
                body: error.localizedDescription
            )
        }

        let modelRelay = ModelRelayService()
        self.modelRelay = modelRelay
        do {
            try modelRelay.start()
        } catch {
            NSLog("Tocode 本地模型中转启动失败: %@", error.localizedDescription)
        }

        // 启动后把 CLI 安装/刷新到用户 PATH（~/.local/bin/tocode）。
        installCLI()

        let togentRuntime = TogentRuntimeService(
            relayAccess: { [modelRelay] in
                modelRelay.togentRelayAccess()
            }
        )
        let togent = TogentService(
            runtime: togentRuntime,
            availableModelOptions: { [modelRelay] in
                modelRelay.router.availableTogentModels()
            },
            relayFingerprint: { [modelRelay] in
                modelRelay.togentRelayFingerprint()
            }
        )
        self.togent = togent
        if let startupError = togent.startupError {
            NSLog("Tocode Togent 启动失败: %@", startupError.localizedDescription)
        }
        modelRelay.didChange = { [weak togent] in
            togent?.relayDidChange()
        }
        executor.attachTogent(togent)
        executor.attachModelRelay(modelRelay)

        let weChat = WeChatAssociationService()
        self.weChat = weChat
        executor.attachWeChat(weChat)
        weChat.commandExecutor = executor
        weChat.attachTogent(togent)

        let controller = StatusItemController(
            shortcuts: service,
            trackpadShortcuts: trackpad,
            keyboardRemaps: keyboardRemaps,
            mouseWheel: wheel,
            dockAutohideRestrict: dockRestrict,
            macTimers: macTimers,
            weChat: weChat,
            screenBlackout: blackout,
            modelRelay: modelRelay,
            togent: togent,
            commandExecutor: executor
        )
        self.controller = controller
        keyboardRemaps.actionHandler = { [weak controller] action in
            controller?.performMappedAction(action)
        }
        trackpad.actionHandler = { [weak controller] action in
            controller?.performMappedAction(action)
        }
        keyboardRemaps.shouldYieldAllEvents = { [weak blackout] in
            blackout?.isPresented == true
        }
        macTimers.fireHandler = { [weak controller] target in
            controller?.performMappedTarget(target)
        }
        macTimers.applySavedSettings()

        weChat.startBoundListener()
    }

    private func installCLI() {
        let targetDirectory = NSHomeDirectory() + "/.local/bin"
        let targetPath = targetDirectory + "/tocode"
        let sourcePath = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("tocode")
            .path

        let fm = FileManager.default
        guard fm.fileExists(atPath: sourcePath) else { return }

        do {
            try fm.createDirectory(
                atPath: targetDirectory,
                withIntermediateDirectories: true
            )
            if let existing = try? Data(contentsOf: URL(fileURLWithPath: targetPath)),
               let source = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)),
               existing == source {
                return
            }
            try fm.removeItemIfExists(at: targetPath)
            try fm.copyItem(atPath: sourcePath, toPath: targetPath)
            try fm.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: targetPath
            )
        } catch {
            NSLog("Tocode CLI 安装到 PATH 失败: %@", error.localizedDescription)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let togent else {
            return .terminateNow
        }
        guard !isPreparingTermination else {
            return .terminateLater
        }
        isPreparingTermination = true
        // 先停止唯一入口，再等待受管 Pi 子进程退出，避免 App 退出后遗留运行时。
        weChat?.stop()
        Task {
            await togent.stopAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        ipcServer?.stop()
        ipcServer = nil
        togent?.stop()
        togent = nil
        modelRelay?.stop()
        modelRelay = nil
        shortcuts?.shutdown()
        trackpadShortcuts?.shutdown()
        keyboardRemaps?.shutdown()
        mouseWheel?.shutdown()
        dockAutohideRestrict?.shutdown()
        macTimers?.shutdown()
        weChat?.stop()
    }
}
