import AppKit

/// 菜单跟踪诊断的接收端。目录树已经有自己的 NSMenuDelegate，不能被探针换掉。
@MainActor
protocol MenuTrackingSinking: AnyObject {
    func menuTrackingHighlight(_ menu: NSMenu, item: NSMenuItem?)
    func menuTrackingItemCountChanged(_ menu: NSMenu, before: Int, after: Int)
    func menuTrackingWillOpen(_ menu: NSMenu)
    func menuTrackingDidClose(_ menu: NSMenu)
}

@MainActor
protocol MenuTrackingForwarding: AnyObject {
    var menuTrackingSink: MenuTrackingSinking? { get set }
}

protocol MenuTrackingRecording: AnyObject {
    func record(_ event: String, detail: [String: Any])
}

/// 菜单跟踪诊断开关。默认关闭，不进入可导出配置。
enum MenuTrackingPreferences {
    static let key = "menuTrackingDiagnostics"

    static func isEnabled(defaults: UserDefaults = TocodePreferences.shared) -> Bool {
        defaults.bool(forKey: key)
    }

    static func setEnabled(_ on: Bool, defaults: UserDefaults = TocodePreferences.shared) {
        defaults.set(on, forKey: key)
    }
}

final class DiagnosticMenuTrackingRecorder: MenuTrackingRecording {
    private let log: DiagnosticLog

    init(log: DiagnosticLog = .shared) {
        self.log = log
    }

    func record(_ event: String, detail: [String: Any]) {
        log.event(event, detail: detail)
    }
}

/// 记录状态栏菜单的高亮、打开和关闭。不记录条目标题、网址或路径。
/// 开关关闭时 begin/attach/end 什么都不做，也不设置 delegate。
@MainActor
final class MenuTrackingProbe: NSObject, NSMenuDelegate, MenuTrackingSinking {
    private static let allowedKinds: Set<String> = ["directory", "bookmarks", "desktop", "actions"]

    private let recorder: MenuTrackingRecording
    private let enabled: () -> Bool
    private var sessionID = 0
    private var sessionActive = false
    private var sessionStarted = Date()
    private var lastTick: Date?
    private var stallTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var tracked: [TrackedMenu] = []

    init(
        recorder: MenuTrackingRecording = DiagnosticMenuTrackingRecorder(),
        enabled: (() -> Bool)? = nil
    ) {
        self.recorder = recorder
        self.enabled = enabled ?? { MenuTrackingPreferences.isEnabled() }
        super.init()
    }

    func begin(kind: String) {
        guard enabled() else { return }
        if sessionActive { end() }
        sessionID += 1
        sessionActive = true
        sessionStarted = Date()
        let safeKind = Self.allowedKinds.contains(kind) ? kind : "other"
        record("menu.session_begin", detail: context(nil, item: nil, extra: ["kind": safeKind]))
        startStallTimer()
        startObservers()
    }

    func attach(_ menu: NSMenu) {
        guard sessionActive else { return }
        attach(menu, depth: 0)
    }

    func end() {
        guard sessionActive else { return }
        record("menu.session_end", detail: context(nil, item: nil))
        sessionActive = false
        stallTimer?.invalidate()
        stallTimer = nil
        lastTick = nil
        for (center, token) in observers {
            center.removeObserver(token)
        }
        observers.removeAll()
        clearTracking()
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        menuTrackingHighlight(menu, item: item)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuTrackingWillOpen(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTrackingDidClose(menu)
    }

    func menuTrackingHighlight(_ menu: NSMenu, item: NSMenuItem?) {
        guard sessionActive else { return }
        if let submenu = item?.submenu {
            rememberUnknown(submenu, parent: menu)
        }
        record("menu.will_highlight", detail: context(menu, item: item))
    }

    func menuTrackingItemCountChanged(_ menu: NSMenu, before: Int, after: Int) {
        guard sessionActive else { return }
        registerChildren(of: menu)
        record(
            "menu.item_count",
            detail: context(menu, item: nil, extra: ["before": before, "after": after])
        )
    }

    func menuTrackingWillOpen(_ menu: NSMenu) {
        guard sessionActive else { return }
        record("menu.will_open", detail: context(menu, item: nil))
        let timer = Timer(timeInterval: 0.04, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordWindowSample()
            }
        }
        RunLoop.current.add(timer, forMode: .eventTracking)
    }

    func menuTrackingDidClose(_ menu: NSMenu) {
        guard sessionActive else { return }
        record("menu.did_close", detail: context(menu, item: nil, extra: Self.windowFacts()))
    }

    /// 打开后 40 毫秒看窗口有没有盖住光标。不记窗口标题。
    private func recordWindowSample() {
        guard sessionActive else { return }
        record("menu.window_sample", detail: context(nil, item: nil, extra: Self.windowFacts()))
    }

    private static func windowFacts() -> [String: Any] {
        let mouse = NSEvent.mouseLocation
        let screenMax = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return ["full_screen": 0, "windows": ""]
        }
        var frames: [String] = []
        var fullScreen = 0
        for dict in info {
            guard (dict[kCGWindowOwnerPID as String] as? Int) == Int(pid) else { continue }
            guard let bounds = dict[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0
            if height > 900 { fullScreen = 1 }
            guard width >= 18, height >= 18, height <= 900, width <= 1400 else { continue }
            let cg = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: width, height: height)
            let frame = CGRect(x: cg.minX, y: screenMax - cg.maxY, width: cg.width, height: cg.height)
            let hit = frame.contains(mouse) ? 1 : 0
            frames.append("\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height)),\(hit)")
            if frames.count == 6 { break }
        }
        return ["full_screen": fullScreen, "windows": frames.joined(separator: ";")]
    }

    private func attach(_ menu: NSMenu, depth: Int) {
        let owns = claim(menu)
        remember(menu, depth: depth, ownsDelegate: owns)
        for item in menu.items {
            if let submenu = item.submenu {
                attach(submenu, depth: depth + 1)
            }
        }
    }

    /// 只在没有 delegate 时接住。已有转发对象则把事件送过来，不替换它。
    private func claim(_ menu: NSMenu) -> Bool {
        if menu.delegate == nil {
            menu.delegate = self
            return true
        }
        if let forwarding = menu.delegate as? MenuTrackingForwarding {
            forwarding.menuTrackingSink = self
        }
        return false
    }

    private func rememberUnknown(_ menu: NSMenu, parent: NSMenu) {
        guard !tracked.contains(where: { $0.menu === menu }) else { return }
        let parentDepth = depth(of: parent)
        let owns = claim(menu)
        remember(menu, depth: parentDepth < 0 ? -1 : parentDepth + 1, ownsDelegate: owns)
        registerChildren(of: menu)
    }

    private func registerChildren(of menu: NSMenu) {
        let parentDepth = depth(of: menu)
        let childDepth = parentDepth < 0 ? -1 : parentDepth + 1
        for item in menu.items {
            guard let submenu = item.submenu else { continue }
            guard !tracked.contains(where: { $0.menu === submenu }) else { continue }
            let owns = claim(submenu)
            remember(submenu, depth: childDepth, ownsDelegate: owns)
            registerChildren(of: submenu)
        }
    }

    private func remember(_ menu: NSMenu, depth: Int, ownsDelegate: Bool) {
        if let index = tracked.firstIndex(where: { $0.menu === menu }) {
            tracked[index].depth = depth
            tracked[index].ownsDelegate = tracked[index].ownsDelegate || ownsDelegate
            return
        }
        tracked.append(TrackedMenu(menu: menu, depth: depth, ownsDelegate: ownsDelegate))
    }

    private func depth(of menu: NSMenu) -> Int {
        tracked.first { $0.menu === menu }?.depth ?? -1
    }

    private func clearTracking() {
        for entry in tracked {
            guard let menu = entry.menu else { continue }
            if entry.ownsDelegate, menu.delegate === self {
                menu.delegate = nil
            }
            if let forwarding = menu.delegate as? MenuTrackingForwarding {
                forwarding.menuTrackingSink = nil
            }
        }
        tracked.removeAll()
    }

    private func startStallTimer() {
        lastTick = Date()
        let timer = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.noteStallTick()
            }
        }
        RunLoop.current.add(timer, forMode: .eventTracking)
        stallTimer = timer
    }

    private func noteStallTick() {
        guard sessionActive else { return }
        let now = Date()
        let gap = now.timeIntervalSince(lastTick ?? now)
        lastTick = now
        guard gap > 0.1 else { return }
        record("menu.stall", detail: context(nil, item: nil, extra: ["gap_ms": Int(gap * 1000)]))
    }

    private func startObservers() {
        observe(NotificationCenter.default, name: NSApplication.didBecomeActiveNotification) { [weak self] _ in
            self?.record("menu.app_active", detail: self?.context(nil, item: nil) ?? [:])
        }
        observe(NotificationCenter.default, name: NSApplication.didResignActiveNotification) { [weak self] _ in
            self?.record("menu.app_resign", detail: self?.context(nil, item: nil) ?? [:])
        }
        observe(
            NSWorkspace.shared.notificationCenter,
            name: NSWorkspace.didActivateApplicationNotification
        ) { [weak self] note in
            let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundle = Self.bundleLabel(running?.bundleIdentifier ?? "")
            self?.record("menu.front_app", detail: self?.context(nil, item: nil, extra: ["bundle": bundle]) ?? [:])
        }
    }

    private func observe(
        _ center: NotificationCenter,
        name: Notification.Name,
        work: @escaping @MainActor (Notification) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                work(note)
            }
        }
        observers.append((center, token))
    }

    private func context(
        _ menu: NSMenu?,
        item: NSMenuItem?,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        let app: NSApplication? = NSApp
        var detail: [String: Any] = [
            "session": sessionID,
            "t_ms": Int(Date().timeIntervalSince(sessionStarted) * 1000),
            "event_type": app?.currentEvent.map { Int($0.type.rawValue) } ?? -1,
            "mouse_x": Int(NSEvent.mouseLocation.x.rounded()),
            "mouse_y": Int(NSEvent.mouseLocation.y.rounded()),
            "app_active": app?.isActive ?? false,
            "key_window_nil": app?.keyWindow == nil,
        ]
        if let event = app?.currentEvent {
            detail["event_dx"] = Int(event.deltaX.rounded())
            detail["event_dy"] = Int(event.deltaY.rounded())
        }
        if let menu {
            detail["depth"] = depth(of: menu)
            detail["items"] = menu.items.count
        }
        if let item {
            let owner = item.menu ?? menu
            detail["index"] = owner.map { $0.index(of: item) } ?? -1
            detail["has_submenu"] = item.submenu != nil
        } else if menu != nil {
            detail["index"] = -1
            detail["has_submenu"] = false
        }
        for (key, value) in extra {
            detail[key] = value
        }
        return detail
    }

    private func record(_ event: String, detail: [String: Any]) {
        guard sessionActive else { return }
        recorder.record(event, detail: detail)
    }

    private static func bundleLabel(_ raw: String) -> String {
        if raw.isEmpty || raw.contains("/") || raw.contains(" ") { return "unknown" }
        if raw.count > 80 { return String(raw.prefix(80)) }
        return raw
    }
}

private struct TrackedMenu {
    weak var menu: NSMenu?
    var depth: Int
    var ownsDelegate: Bool
}
