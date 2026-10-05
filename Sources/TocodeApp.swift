import AppKit

@main
struct TocodeApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        ApplicationEditMenu.install(on: app)

        let delegate = AppDelegate()
        app.delegate = delegate

        app.run()
    }
}
