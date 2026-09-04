import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var shortcuts: GlobalShortcutService?
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let service = GlobalShortcutService()
        service.applySavedSettings()
        shortcuts = service
        controller = StatusItemController(shortcuts: service)
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcuts?.shutdown()
    }
}
