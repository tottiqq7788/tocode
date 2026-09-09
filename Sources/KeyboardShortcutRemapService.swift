import CoreGraphics
import Foundation

enum KeyboardShortcutRemapDisposition: Equatable {
    case pass
    case suppress
}

protocol KeyboardShortcutRemapTapControlling: AnyObject {
    var isInstalled: Bool { get }
    var isEnabled: Bool { get }
    func install(
        handler: @escaping (CGEventType, CGEvent) -> KeyboardShortcutRemapDisposition
    ) -> Bool
    func remove()
    func reenable() -> Bool
}

protocol KeyboardShortcutRemapControlling: AnyObject {
    var mappings: [KeyboardShortcutMapping] { get }
    func setInputCaptureSuspended(_ suspended: Bool)
    func claims(type: CGEventType, event: CGEvent) -> Bool
    @discardableResult
    func saveMapping(
        _ draft: KeyboardShortcutMappingDraft
    ) -> Result<KeyboardShortcutMapping, KeyboardShortcutMappingValidationError>
    func deleteMapping(id: UUID)
}

final class KeyboardShortcutRemapService: KeyboardShortcutRemapControlling {
    private let store: KeyboardShortcutMappingStore
    private let permissions: ShortcutPermissionChecking
    private let tap: KeyboardShortcutRemapTapControlling
    private let poster: TrackpadShortcutEventPosting
    private let scheduler: ShortcutScheduling
    private let alerts: ShortcutAlerting
    private var engine: KeyboardShortcutRemapEngine
    private var inputCaptureSuspended = false
    private(set) var mappings: [KeyboardShortcutMapping]

    init(
        store: KeyboardShortcutMappingStore = KeyboardShortcutMappingStore(),
        permissions: ShortcutPermissionChecking = SystemShortcutPermissionGate(),
        tap: KeyboardShortcutRemapTapControlling = CGEventKeyboardShortcutRemapTap(),
        poster: TrackpadShortcutEventPosting = SystemTrackpadShortcutEventPoster(),
        scheduler: ShortcutScheduling = MainQueueShortcutScheduler(),
        alerts: ShortcutAlerting = UserNotificationShortcutAlert()
    ) {
        self.store = store
        self.permissions = permissions
        self.tap = tap
        self.poster = poster
        self.scheduler = scheduler
        self.alerts = alerts
        let storedMappings = store.allMappings()
        mappings = storedMappings
        engine = KeyboardShortcutRemapEngine(mappings: storedMappings)
    }

    func applySavedSettings() {
        reloadMappings()
        reconcileTap()
    }

    @discardableResult
    func saveMapping(
        _ draft: KeyboardShortcutMappingDraft
    ) -> Result<KeyboardShortcutMapping, KeyboardShortcutMappingValidationError> {
        let result = store.save(draft)
        if case .success = result {
            reloadMappings()
            reconcileTap()
        }
        return result
    }

    func deleteMapping(id: UUID) {
        store.delete(id: id)
        reloadMappings()
        reconcileTap()
    }

    func shutdown() {
        inputCaptureSuspended = false
        tap.remove()
    }

    func setInputCaptureSuspended(_ suspended: Bool) {
        inputCaptureSuspended = suspended
    }

    func claims(type: CGEventType, event: CGEvent) -> Bool {
        guard
            !inputCaptureSuspended,
            tap.isInstalled,
            tap.isEnabled,
            let snapshot = KeyboardShortcutEventSnapshot.capture(type: type, event: event)
        else {
            return false
        }
        return engine.claims(snapshot)
    }

    @discardableResult
    func handleSnapshot(_ snapshot: KeyboardShortcutEventSnapshot) -> KeyboardShortcutRemapStep {
        guard !inputCaptureSuspended else { return .pass }
        let step = engine.process(snapshot)
        perform(step)
        return step
    }

    private func reloadMappings() {
        mappings = store.allMappings()
        engine.replaceMappings(mappings)
    }

    private func reconcileTap() {
        guard !mappings.isEmpty else {
            tap.remove()
            return
        }
        _ = ensureTapRunning()
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
                title: "键盘映射需要辅助功能权限",
                body: "请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 Tocode。规则已保留，其他输入功能不受影响。"
            )
            return false
        }

        let installed = tap.install { [weak self] type, event in
            self?.handleTap(type: type, event: event) ?? .pass
        }
        if !installed {
            alerts.notify(
                title: "键盘映射监听未启动",
                body: "系统事件钩子创建失败。规则已保留，其他输入功能不受影响。"
            )
            return false
        }
        return true
    }

    private func handleTap(
        type: CGEventType,
        event: CGEvent
    ) -> KeyboardShortcutRemapDisposition {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if !tap.reenable() {
                scheduler.async { [weak self] in
                    self?.stopListeningAfterFailure()
                }
            }
            return .pass
        }
        if inputCaptureSuspended {
            return .pass
        }
        guard let snapshot = KeyboardShortcutEventSnapshot.capture(type: type, event: event) else {
            return .pass
        }

        let step = engine.process(snapshot)
        perform(step)
        switch step {
        case .pass:
            return .pass
        case .suppress, .emit:
            return .suppress
        }
    }

    private func perform(_ step: KeyboardShortcutRemapStep) {
        guard case .emit(let target) = step else { return }
        scheduler.async { [weak self] in
            guard let self else { return }
            if !self.poster.post(target) {
                self.alerts.notify(
                    title: "键盘映射发送失败",
                    body: "目标快捷键未能发送。规则已保留，其他输入功能不受影响。"
                )
            }
        }
    }

    private func stopListeningAfterFailure() {
        tap.remove()
        alerts.notify(
            title: "键盘映射监听已停止",
            body: "系统事件钩子被停用且无法恢复。规则已保留，其他输入功能不受影响。"
        )
    }
}

final class CGEventKeyboardShortcutRemapTap: KeyboardShortcutRemapTapControlling {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: ((CGEventType, CGEvent) -> KeyboardShortcutRemapDisposition)?

    var isInstalled: Bool { port != nil }

    var isEnabled: Bool {
        guard let port else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    func install(
        handler: @escaping (CGEventType, CGEvent) -> KeyboardShortcutRemapDisposition
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
            let tap = Unmanaged<CGEventKeyboardShortcutRemapTap>
                .fromOpaque(refcon)
                .takeUnretainedValue()
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
