import AppKit
import CoreGraphics
import Foundation

protocol TrackpadShortcutControlling: AnyObject {
    func shortcut(for gesture: TrackpadTapGesture) -> RecordedShortcut?
    @discardableResult
    func setShortcut(_ shortcut: RecordedShortcut, for gesture: TrackpadTapGesture) -> Bool
    func clearShortcut(for gesture: TrackpadTapGesture)
}

protocol TrackpadShortcutEventPosting {
    @discardableResult
    func post(_ shortcut: RecordedShortcut) -> Bool
}

struct SystemTrackpadShortcutEventPoster: TrackpadShortcutEventPosting {
    @discardableResult
    func post(_ shortcut: RecordedShortcut) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(shortcut.keyCode),
                keyDown: true
            ),
            let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(shortcut.keyCode),
                keyDown: false
            )
        else {
            return false
        }

        down.flags = shortcut.modifiers.eventFlags
        up.flags = shortcut.modifiers.eventFlags
        down.setIntegerValueField(
            .eventSourceUserData,
            value: GlobalShortcutEngine.synthesizerMarker
        )
        up.setIntegerValueField(
            .eventSourceUserData,
            value: GlobalShortcutEngine.synthesizerMarker
        )
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

final class TrackpadShortcutService: NSObject, TrackpadShortcutControlling {
    private let store: TrackpadShortcutStore
    private let monitor: MultitouchMonitoring
    private let permissions: ShortcutPermissionChecking
    private let poster: TrackpadShortcutEventPosting
    private let alerts: ShortcutAlerting
    private let lock = NSLock()
    private var shortcuts: [TrackpadTapGesture: RecordedShortcut] = [:]
    private var recognizers: [UInt: TrackpadTapRecognizer] = [:]
    private var observingWake = false

    init(
        store: TrackpadShortcutStore = TrackpadShortcutStore(),
        monitor: MultitouchMonitoring = PrivateMultitouchMonitor(),
        permissions: ShortcutPermissionChecking = SystemShortcutPermissionGate(),
        poster: TrackpadShortcutEventPosting = SystemTrackpadShortcutEventPoster(),
        alerts: ShortcutAlerting = UserNotificationShortcutAlert()
    ) {
        self.store = store
        self.monitor = monitor
        self.permissions = permissions
        self.poster = poster
        self.alerts = alerts
        super.init()
    }

    func applySavedSettings() {
        lock.lock()
        shortcuts = store.allShortcuts()
        let hasShortcuts = !shortcuts.isEmpty
        lock.unlock()

        if hasShortcuts {
            startListeningAndRequestPermission()
        } else {
            monitor.stop()
        }
        startWakeObservationIfNeeded()
    }

    func shortcut(for gesture: TrackpadTapGesture) -> RecordedShortcut? {
        lock.lock()
        defer { lock.unlock() }
        return shortcuts[gesture] ?? store.shortcut(for: gesture)
    }

    @discardableResult
    func setShortcut(_ shortcut: RecordedShortcut, for gesture: TrackpadTapGesture) -> Bool {
        store.setShortcut(shortcut, for: gesture)
        lock.lock()
        shortcuts[gesture] = shortcut
        lock.unlock()
        startWakeObservationIfNeeded()
        return startListeningAndRequestPermission()
    }

    func clearShortcut(for gesture: TrackpadTapGesture) {
        store.removeShortcut(for: gesture)
        lock.lock()
        shortcuts.removeValue(forKey: gesture)
        let shouldStop = shortcuts.isEmpty
        if shouldStop {
            recognizers.removeAll()
        }
        lock.unlock()
        if shouldStop {
            monitor.stop()
        }
    }

    func shutdown() {
        if observingWake {
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            observingWake = false
        }
        monitor.stop()
        lock.lock()
        recognizers.removeAll()
        lock.unlock()
    }

    @discardableResult
    private func startListeningAndRequestPermission() -> Bool {
        let started: Bool
        if monitor.isRunning {
            started = true
        } else {
            lock.lock()
            recognizers.removeAll()
            lock.unlock()
            started = monitor.start { [weak self] frame in
                self?.handle(frame)
            }
        }

        if !started {
            alerts.notify(
                title: "触控板监听未启动",
                body: "系统触控接口或触控设备当前不可用。快捷键配置已保留，其他输入功能不受影响。"
            )
            return false
        }

        if !permissions.hasAccessibilityAccess() && !permissions.requestAccessibilityAccess() {
            alerts.notify(
                title: "触控板快捷键需要辅助功能权限",
                body: "请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 Tocode。配置已保留。"
            )
            return false
        }
        return true
    }

    private func startWakeObservationIfNeeded() {
        guard !observingWake else { return }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        observingWake = true
    }

    @objc private func handleWake() {
        lock.lock()
        let shouldRestart = !shortcuts.isEmpty
        recognizers.removeAll()
        lock.unlock()
        guard shouldRestart else { return }

        monitor.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            _ = self?.startListeningAndRequestPermission()
        }
    }

    private func handle(_ frame: MultitouchContactFrame) {
        var shortcut: RecordedShortcut?

        lock.lock()
        var recognizer = recognizers[frame.deviceID] ?? TrackpadTapRecognizer()
        let gesture = recognizer.process(
            TrackpadTouchSample(
                touchCount: frame.touchCount,
                timestamp: frame.timestamp,
                firstPosition: frame.firstPosition
            )
        )
        recognizers[frame.deviceID] = recognizer
        if let gesture {
            shortcut = shortcuts[gesture]
        }
        lock.unlock()

        guard let shortcut else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.poster.post(shortcut) {
                self.alerts.notify(
                    title: "触控板快捷键发送失败",
                    body: "快捷键配置已保留，其他输入功能不受影响。"
                )
            }
        }
    }
}
