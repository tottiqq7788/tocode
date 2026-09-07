import ApplicationServices
import CoreGraphics

struct ScrollWheelSnapshot: Equatable {
    var isContinuous: Bool
    var line1: Int64
    var point1: Int64
    var fixed1: Double
    var line2: Int64
    var point2: Int64
    var fixed2: Double
}

/// 只对非连续滚轮按轴向取反；连续滚动原样返回。
enum MouseWheelReverse {
    static func apply(
        _ snapshot: ScrollWheelSnapshot,
        reverseVertical: Bool,
        reverseHorizontal: Bool
    ) -> ScrollWheelSnapshot {
        guard !snapshot.isContinuous else { return snapshot }
        var next = snapshot
        if reverseVertical {
            next.line1 = -next.line1
            next.point1 = -next.point1
            next.fixed1 = -next.fixed1
        }
        if reverseHorizontal {
            next.line2 = -next.line2
            next.point2 = -next.point2
            next.fixed2 = -next.fixed2
        }
        return next
    }

    static func snapshot(from event: CGEvent) -> ScrollWheelSnapshot {
        ScrollWheelSnapshot(
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            line1: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            point1: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            fixed1: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            line2: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            point2: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
            fixed2: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        )
    }

    static func write(_ snapshot: ScrollWheelSnapshot, to event: CGEvent) {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: snapshot.line1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: snapshot.point1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: snapshot.fixed1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: snapshot.line2)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: snapshot.point2)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: snapshot.fixed2)
    }
}

protocol MouseWheelTapControlling: AnyObject {
    var isInstalled: Bool { get }
    var isEnabled: Bool { get }
    func install(handler: @escaping (CGEventType, CGEvent) -> Void) -> Bool
    func remove()
    func reenable() -> Bool
}

/// 独立滚动钩子：失败只关闭滚轮开关，不拆除快捷键钩子。
final class MouseWheelReverseService {
    private let settings: MouseWheelReverseStore
    private let permissions: ShortcutPermissionChecking
    private let tap: MouseWheelTapControlling
    private let scheduler: ShortcutScheduling
    private let alerts: ShortcutAlerting
    private var verticalArmed = false
    private var horizontalArmed = false

    init(
        settings: MouseWheelReverseStore = MouseWheelReverseStore(),
        permissions: ShortcutPermissionChecking = SystemShortcutPermissionGate(),
        tap: MouseWheelTapControlling = CGEventMouseWheelTap(),
        scheduler: ShortcutScheduling = MainQueueShortcutScheduler(),
        alerts: ShortcutAlerting = UserNotificationShortcutAlert()
    ) {
        self.settings = settings
        self.permissions = permissions
        self.tap = tap
        self.scheduler = scheduler
        self.alerts = alerts
    }

    var isVerticalEffective: Bool {
        settings.reverseVerticalEnabled && verticalArmed && tap.isInstalled && tap.isEnabled
    }

    var isHorizontalEffective: Bool {
        settings.reverseHorizontalEnabled && horizontalArmed && tap.isInstalled && tap.isEnabled
    }

    func applySavedSettings() {
        let wantVertical = settings.reverseVerticalEnabled
        let wantHorizontal = settings.reverseHorizontalEnabled
        verticalArmed = false
        horizontalArmed = false
        guard wantVertical || wantHorizontal else { return }
        guard ensureTapRunning() else {
            settings.reverseVerticalEnabled = false
            settings.reverseHorizontalEnabled = false
            return
        }
        verticalArmed = wantVertical
        horizontalArmed = wantHorizontal
    }

    @discardableResult
    func setVerticalEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            settings.reverseVerticalEnabled = false
            verticalArmed = false
            tearDownTapIfIdle()
            return true
        }
        settings.reverseVerticalEnabled = true
        guard ensureTapRunning() else {
            settings.reverseVerticalEnabled = false
            verticalArmed = false
            tearDownTapIfIdle()
            return false
        }
        verticalArmed = true
        return true
    }

    @discardableResult
    func setHorizontalEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            settings.reverseHorizontalEnabled = false
            horizontalArmed = false
            tearDownTapIfIdle()
            return true
        }
        settings.reverseHorizontalEnabled = true
        guard ensureTapRunning() else {
            settings.reverseHorizontalEnabled = false
            horizontalArmed = false
            tearDownTapIfIdle()
            return false
        }
        horizontalArmed = true
        return true
    }

    func shutdown() {
        verticalArmed = false
        horizontalArmed = false
        tap.remove()
    }

    /// 测试入口：走完整判定并写回事件字段，不创建真实钩子。
    func handleScroll(_ event: CGEvent) {
        applyToEvent(event)
    }

    private func ensureTapRunning() -> Bool {
        if tap.isInstalled && tap.isEnabled {
            return true
        }
        if tap.isInstalled, tap.reenable() {
            return true
        }
        guard permissions.hasAccessibilityAccess() || permissions.requestAccessibilityAccess() else {
            alerts.notify(
                title: "无法对调鼠标滚轮",
                body: "请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 Tocode，然后再次点击开关。未授权时滚动原样透传。"
            )
            return false
        }
        let installed = tap.install { [weak self] type, event in
            self?.handleTap(type: type, event: event)
        }
        if !installed {
            alerts.notify(
                title: "无法对调鼠标滚轮",
                body: "系统滚动钩子创建失败，滚动原样透传。"
            )
            return false
        }
        return true
    }

    private func tearDownTapIfIdle() {
        if !verticalArmed && !horizontalArmed {
            tap.remove()
        }
    }

    private func handleTap(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if !tap.reenable() {
                scheduler.async { [weak self] in
                    self?.failOpenStop(message: "滚动钩子被停用，无法恢复。鼠标与触控板滚动已原样放行。")
                }
            }
            return
        }
        guard type == .scrollWheel else { return }
        applyToEvent(event)
    }

    private func applyToEvent(_ event: CGEvent) {
        let next = MouseWheelReverse.apply(
            MouseWheelReverse.snapshot(from: event),
            reverseVertical: verticalArmed,
            reverseHorizontal: horizontalArmed
        )
        MouseWheelReverse.write(next, to: event)
    }

    private func failOpenStop(message: String) {
        verticalArmed = false
        horizontalArmed = false
        settings.reverseVerticalEnabled = false
        settings.reverseHorizontalEnabled = false
        tap.remove()
        alerts.notify(title: "滚轮对调已关闭", body: message)
    }
}

final class CGEventMouseWheelTap: MouseWheelTapControlling {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: ((CGEventType, CGEvent) -> Void)?

    var isInstalled: Bool { port != nil }

    var isEnabled: Bool {
        guard let port else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    func install(handler: @escaping (CGEventType, CGEvent) -> Void) -> Bool {
        remove()
        self.handler = handler
        let mask =
            (CGEventMask(1) << CGEventType.scrollWheel.rawValue)
            | (CGEventMask(1) << CGEventType.tapDisabledByTimeout.rawValue)
            | (CGEventMask(1) << CGEventType.tapDisabledByUserInput.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }
            let tap = Unmanaged<CGEventMouseWheelTap>.fromOpaque(refcon).takeUnretainedValue()
            tap.handler?(type, event)
            return Unmanaged.passUnretained(event)
        }
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            self.handler = nil
            return false
        }
        let loopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        port = created
        source = loopSource
        return true
    }

    func remove() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let port {
            CFMachPortInvalidate(port)
        }
        port = nil
        source = nil
        handler = nil
    }

    func reenable() -> Bool {
        guard let port else { return false }
        CGEvent.tapEnable(tap: port, enable: true)
        return CGEvent.tapIsEnabled(tap: port)
    }
}
