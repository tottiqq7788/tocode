import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var shortcuts: GlobalShortcutService?
    private var mouseWheel: MouseWheelReverseService?
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let service = GlobalShortcutService()
        service.applySavedSettings()
        shortcuts = service
        let wheel = MouseWheelReverseService()
        wheel.applySavedSettings()
        mouseWheel = wheel
        controller = StatusItemController(shortcuts: service, mouseWheel: wheel)
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcuts?.shutdown()
        mouseWheel?.shutdown()
    }
}
