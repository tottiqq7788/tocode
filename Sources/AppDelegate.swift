import AppKit

@MainActor
private final class UnboundWeChat: WeChatAssociationControlling {
    var isBound: Bool { false }
    func startBinding() {}
    func startBoundListener() {}
    func openArchiveLocation() {}
    func stop() {}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var shortcuts: GlobalShortcutService?
    private var mouseWheel: MouseWheelReverseService?
    private var weChat: WeChatAssociationService?
    private var controller: StatusItemController?
    private var commandExecutor: TocodeCommandExecutor?
    private var ipcServer: TocodeIPCServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let service = GlobalShortcutService()
        service.applySavedSettings()
        shortcuts = service
        let wheel = MouseWheelReverseService()
        wheel.applySavedSettings()
        mouseWheel = wheel

        // 先启动 IPC，避免微信 Keychain 初始化阻塞命令入口。
        let executor = TocodeCommandExecutor(
            mouseWheel: wheel,
            shortcuts: service,
            codexModels: CodexModelSwitchService(),
            weChat: UnboundWeChat()
        )
        commandExecutor = executor

        let server = TocodeIPCServer(executor: executor)
        do {
            try server.start()
            ipcServer = server
        } catch {
            NSLog("Tocode IPC server 启动失败: %@", error.localizedDescription)
        }

        let weChat = WeChatAssociationService()
        self.weChat = weChat
        executor.attachWeChat(weChat)
        weChat.commandExecutor = executor

        let blackout = ScreenBlackoutService(overlay: ScreenBlackoutOverlay())
        controller = StatusItemController(
            shortcuts: service,
            mouseWheel: wheel,
            weChat: weChat,
            screenBlackout: blackout
        )

        weChat.startBoundListener()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ipcServer?.stop()
        ipcServer = nil
        shortcuts?.shutdown()
        mouseWheel?.shutdown()
        weChat?.stop()
    }
}
