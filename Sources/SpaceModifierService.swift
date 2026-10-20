import CoreGraphics
import Foundation

protocol SpaceModifierControlling: AnyObject {
    var isEffective: Bool { get }
    /// 空格修饰键已生效，且空格正处于按住状态。关闭或未安装钩子时为 false。
    var isTottiHeld: Bool { get }
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool
    func applySavedSettings()
}

protocol SpaceModifierTapControlling: AnyObject {
    var isInstalled: Bool { get }
    var isEnabled: Bool { get }
    func install(
        handler: @escaping (CGEventType, CGEvent) -> SpaceModifierDisposition
    ) -> Bool
    func remove()
    func reenable() -> Bool
}

protocol SpaceBarPosting {
    func postSpace()
}

enum SpaceModifierDisposition: Equatable {
    case pass
    case suppress
}

struct SpaceModifierStore {
    static let enabledKey = "tocode.spaceModifierEnabled"

    let defaults: UserDefaults

    init(defaults: UserDefaults = TocodePreferences.shared) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }
}

struct SystemSpaceBarPoster: SpaceBarPosting {
    func postSpace() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode = CGKeyCode(SpaceModifierEngine.spaceKeyCode)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return
        }
        down.flags = []
        up.flags = []
        down.setIntegerValueField(.eventSourceUserData, value: GlobalShortcutEngine.synthesizerMarker)
        up.setIntegerValueField(.eventSourceUserData, value: GlobalShortcutEngine.synthesizerMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

/// 独立键盘钩子：失败只关闭空格修饰键，不拆除其他输入钩子。
final class SpaceModifierService: SpaceModifierControlling {
    private let store: SpaceModifierStore
    private let permissions: ShortcutPermissionChecking
    private let tap: SpaceModifierTapControlling
    private let poster: SpaceBarPosting
    private let clock: ShortcutClock
    private let scheduler: ShortcutScheduling
    private let alerts: ShortcutAlerting
    private var engine = SpaceModifierEngine()
    private var engaged = false
    var shouldYieldAllEvents: (() -> Bool)?

    init(
        store: SpaceModifierStore = SpaceModifierStore(),
        permissions: ShortcutPermissionChecking = SystemShortcutPermissionGate(),
        tap: SpaceModifierTapControlling = CGEventSpaceModifierTap(),
        poster: SpaceBarPosting = SystemSpaceBarPoster(),
        clock: ShortcutClock = SystemShortcutClock(),
        scheduler: ShortcutScheduling = MainQueueShortcutScheduler(),
        alerts: ShortcutAlerting = UserNotificationShortcutAlert()
    ) {
        self.store = store
        self.permissions = permissions
        self.tap = tap
        self.poster = poster
        self.clock = clock
        self.scheduler = scheduler
        self.alerts = alerts
    }

    var isEffective: Bool {
        store.isEnabled && engaged && tap.isInstalled && tap.isEnabled
    }

    var isTottiHeld: Bool {
        engaged && engine.isTottiHeld
    }

    func applySavedSettings() {
        engaged = false
        engine.reset()
        guard store.isEnabled else {
            tap.remove()
            return
        }
        guard ensureTapRunning() else {
            disableAfterFailure()
            return
        }
        engaged = true
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            store.isEnabled = false
            engaged = false
            engine.reset()
            tap.remove()
            return true
        }
        store.isEnabled = true
        guard ensureTapRunning() else {
            disableAfterFailure()
            return false
        }
        engaged = true
        return true
    }

    func shutdown() {
        engaged = false
        engine.reset()
        tap.remove()
    }

    /// 其他键盘钩子刚插入队首后调用，把本钩子重新装到最前面。
    func reassertHeadPosition() {
        guard store.isEnabled, tap.isInstalled else { return }
        tap.remove()
        guard ensureTapRunning() else {
            disableAfterFailure()
            return
        }
        engaged = true
    }

    private func ensureTapRunning() -> Bool {
        if tap.isInstalled && tap.isEnabled {
            return true
        }
        if tap.isInstalled, tap.reenable() {
            return true
        }
        if tap.isInstalled {
            tap.remove()
        }
        guard permissions.hasAccessibilityAccess() || permissions.requestAccessibilityAccess() else {
            alerts.notify(
                title: "空格修饰键需要辅助功能权限",
                body: "请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 Tocode。开关已关闭，其他输入功能不受影响。"
            )
            return false
        }
        let installed = tap.install { [weak self] type, event in
            self?.handleTap(type: type, event: event) ?? .pass
        }
        if !installed {
            alerts.notify(
                title: "空格修饰键监听未启动",
                body: "系统事件钩子创建失败。开关已关闭，其他输入功能不受影响。"
            )
            return false
        }
        return true
    }

    private func disableAfterFailure() {
        store.isEnabled = false
        engaged = false
        engine.reset()
        tap.remove()
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> SpaceModifierDisposition {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if !tap.reenable() {
                scheduler.async { [weak self] in
                    self?.failOpenStop()
                }
            }
            return .pass
        }
        if shouldYieldAllEvents?() == true {
            engine.reset()
            return .pass
        }
        let decision = decide(type: type, event: event, now: clock.now())
        switch decision {
        case .pass:
            return .pass
        case .suppress:
            return .suppress
        case .emitSpace:
            scheduler.async { [weak self] in
                self?.poster.postSpace()
            }
            return .suppress
        case .passMarkingTotti:
            if event.getIntegerValueField(.eventSourceUserData) != GlobalShortcutEngine.synthesizerMarker {
                event.setIntegerValueField(
                    .eventSourceUserData,
                    value: SpaceModifierEngine.tottiMarker
                )
            }
            return .pass
        }
    }

    private func decide(type: CGEventType, event: CGEvent, now: Date) -> SpaceModifierDecision {
        guard type == .keyDown || type == .keyUp else { return .pass }
        let rawKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard rawKeyCode >= 0, rawKeyCode <= Int64(UInt16.max) else { return .pass }
        let userData = event.getIntegerValueField(.eventSourceUserData)
        return engine.process(
            SpaceModifierEvent(
                keyCode: UInt16(rawKeyCode),
                isKeyDown: type == .keyDown,
                isAutoRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                isSynthesized: userData == GlobalShortcutEngine.synthesizerMarker,
                heldSystemModifiers: ShortcutModifiers(systemFlags: event.flags),
                time: now.timeIntervalSinceReferenceDate
            )
        )
    }

    private func failOpenStop() {
        disableAfterFailure()
        alerts.notify(
            title: "空格修饰键监听已停止",
            body: "系统事件钩子被停用且无法恢复。开关已关闭，其他输入功能不受影响。"
        )
    }
}

final class CGEventSpaceModifierTap: SpaceModifierTapControlling {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: ((CGEventType, CGEvent) -> SpaceModifierDisposition)?

    var isInstalled: Bool { port != nil }

    var isEnabled: Bool {
        guard let port else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    func install(
        handler: @escaping (CGEventType, CGEvent) -> SpaceModifierDisposition
    ) -> Bool {
        remove()
        self.handler = handler
        let mask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.tapDisabledByTimeout.rawValue)
            | (CGEventMask(1) << CGEventType.tapDisabledByUserInput.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }
            let tap = Unmanaged<CGEventSpaceModifierTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.invoke(type: type, event: event)
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

    private func invoke(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let disposition = handler?(type, event) ?? .pass
        return disposition == .suppress ? nil : Unmanaged.passUnretained(event)
    }
}
