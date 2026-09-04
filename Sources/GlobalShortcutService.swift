import ApplicationServices
import AppKit
import CoreGraphics
import UserNotifications

protocol ShortcutPermissionChecking {
    func hasAccessibilityAccess() -> Bool
    func requestAccessibilityAccess() -> Bool
}

protocol ShortcutTapControlling: AnyObject {
    var isInstalled: Bool { get }
    var isEnabled: Bool { get }
    func install(handler: @escaping (CGEventType, CGEvent) -> ShortcutAction) -> Bool
    func remove()
    func reenable() -> Bool
}

protocol FrontmostApplicationProviding {
    func frontmost() -> FrontmostAppInfo?
}

protocol FilePasteboardReading {
    var changeCount: Int { get }
    func containsFileURLs() -> Bool
}

protocol FinderEditingContextChecking {
    func isEditingText() -> Bool
}

protocol ShortcutClock {
    func now() -> Date
}

protocol ShortcutScheduling {
    func async(_ work: @escaping () -> Void)
    func asyncAfter(_ seconds: TimeInterval, _ work: @escaping () -> Void)
}

protocol ShortcutAlerting {
    func notify(title: String, body: String)
}

/// 共享 CGEventTap：权限或钩子失败时关闭有效开关并放行全部按键。
final class GlobalShortcutService {
    static let cutVerifyDelay: TimeInterval = 0.08

    private let settings: ShortcutSettingsStore
    private let permissions: ShortcutPermissionChecking
    private let tap: ShortcutTapControlling
    private let frontmostApps: FrontmostApplicationProviding
    private let commandQTargets: CommandQTargetProviding
    private let pasteboard: FilePasteboardReading
    private let synthesizer: KeyboardEventSynthesizing
    private let editingContext: FinderEditingContextChecking
    private let dismisser: FinderWindowDismissing
    private let clock: ShortcutClock
    private let scheduler: ShortcutScheduling
    private let alerts: ShortcutAlerting
    private var engine = GlobalShortcutEngine()

    init(
        settings: ShortcutSettingsStore = ShortcutSettingsStore(),
        permissions: ShortcutPermissionChecking = SystemShortcutPermissionGate(),
        tap: ShortcutTapControlling = CGEventShortcutTap(),
        frontmostApps: FrontmostApplicationProviding = WorkspaceFrontmostApplication(),
        commandQTargets: CommandQTargetProviding? = nil,
        pasteboard: FilePasteboardReading = GeneralFilePasteboard(),
        synthesizer: KeyboardEventSynthesizing = KeyboardEventSynthesizer(),
        editingContext: FinderEditingContextChecking = SystemFinderEditingContext(),
        dismisser: FinderWindowDismissing = FinderDismissService(),
        clock: ShortcutClock = SystemShortcutClock(),
        scheduler: ShortcutScheduling = MainQueueShortcutScheduler(),
        alerts: ShortcutAlerting = UserNotificationShortcutAlert()
    ) {
        self.settings = settings
        self.permissions = permissions
        self.tap = tap
        self.frontmostApps = frontmostApps
        self.commandQTargets = commandQTargets ?? WorkspaceCommandQTargetProvider(frontmost: frontmostApps)
        self.pasteboard = pasteboard
        self.synthesizer = synthesizer
        self.editingContext = editingContext
        self.dismisser = dismisser
        self.clock = clock
        self.scheduler = scheduler
        self.alerts = alerts
    }

    var isFinderMoveEffective: Bool {
        settings.finderMoveHotkeysEnabled && engine.finderMoveEnabled && tap.isInstalled && tap.isEnabled
    }

    var isDoubleCommandQEffective: Bool {
        settings.doubleCommandQEnabled && engine.doubleCommandQEnabled && tap.isInstalled && tap.isEnabled
    }

    var isFinderCommandQEffective: Bool {
        settings.finderCommandQEnabled && engine.finderCommandQEnabled && tap.isInstalled && tap.isEnabled
    }

    func applySavedSettings() {
        let wantMove = settings.finderMoveHotkeysEnabled
        let wantQuit = settings.doubleCommandQEnabled
        let wantFinderQ = settings.finderCommandQEnabled
        engine.setFinderMoveEnabled(false)
        engine.setDoubleCommandQEnabled(false)
        engine.setFinderCommandQEnabled(false)
        guard wantMove || wantQuit || wantFinderQ else { return }
        guard ensureTapRunning() else {
            settings.finderMoveHotkeysEnabled = false
            settings.doubleCommandQEnabled = false
            settings.finderCommandQEnabled = false
            return
        }
        engine.setFinderMoveEnabled(wantMove)
        engine.setDoubleCommandQEnabled(wantQuit)
        engine.setFinderCommandQEnabled(wantFinderQ)
    }

    @discardableResult
    func setFinderMoveEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            settings.finderMoveHotkeysEnabled = false
            engine.setFinderMoveEnabled(false)
            tearDownTapIfIdle()
            return true
        }
        settings.finderMoveHotkeysEnabled = true
        guard ensureTapRunning() else {
            settings.finderMoveHotkeysEnabled = false
            engine.setFinderMoveEnabled(false)
            tearDownTapIfIdle()
            return false
        }
        engine.setFinderMoveEnabled(true)
        return true
    }

    @discardableResult
    func setDoubleCommandQEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            settings.doubleCommandQEnabled = false
            engine.setDoubleCommandQEnabled(false)
            tearDownTapIfIdle()
            return true
        }
        settings.doubleCommandQEnabled = true
        guard ensureTapRunning() else {
            settings.doubleCommandQEnabled = false
            engine.setDoubleCommandQEnabled(false)
            tearDownTapIfIdle()
            return false
        }
        engine.setDoubleCommandQEnabled(true)
        return true
    }

    @discardableResult
    func setFinderCommandQEnabled(_ enabled: Bool) -> Bool {
        if !enabled {
            settings.finderCommandQEnabled = false
            engine.setFinderCommandQEnabled(false)
            tearDownTapIfIdle()
            return true
        }
        settings.finderCommandQEnabled = true
        guard ensureTapRunning() else {
            settings.finderCommandQEnabled = false
            engine.setFinderCommandQEnabled(false)
            tearDownTapIfIdle()
            return false
        }
        engine.setFinderCommandQEnabled(true)
        return true
    }

    func shutdown() {
        engine.setFinderMoveEnabled(false)
        engine.setDoubleCommandQEnabled(false)
        engine.setFinderCommandQEnabled(false)
        tap.remove()
    }

    /// 测试入口：走完整决策与副作用调度，不创建真实钩子。
    @discardableResult
    func handleSnapshot(_ event: KeyboardEventSnapshot) -> ShortcutStep {
        let step = process(event)
        perform(step.effect)
        return step
    }

    var isCutPrepared: Bool { engine.isCutPrepared }

    private func ensureTapRunning() -> Bool {
        if tap.isInstalled && tap.isEnabled {
            return true
        }
        if tap.isInstalled, tap.reenable() {
            return true
        }
        guard permissions.hasAccessibilityAccess() || permissions.requestAccessibilityAccess() else {
            alerts.notify(
                title: "无法开启快捷键",
                body: "请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 Tocode，然后再次点击开关。未授权时所有按键原样放行。"
            )
            return false
        }
        let installed = tap.install { [weak self] type, event in
            self?.handleTap(type: type, event: event) ?? .pass
        }
        if !installed {
            alerts.notify(
                title: "无法开启快捷键",
                body: "系统事件钩子创建失败，所有按键原样放行。"
            )
            return false
        }
        return true
    }

    private func tearDownTapIfIdle() {
        if !engine.finderMoveEnabled && !engine.doubleCommandQEnabled && !engine.finderCommandQEnabled {
            tap.remove()
        }
    }

    private func process(_ event: KeyboardEventSnapshot) -> ShortcutStep {
        let frontmost = frontmostApps.frontmost()
        let qTarget = commandQTargets.commandQTarget()
        return engine.process(
            event,
            frontmost: frontmost,
            now: clock.now(),
            pasteboardChangeCount: pasteboard.changeCount,
            commandQTarget: qTarget,
            commandQTargetUnknown: qTarget == nil && event.key == .commandQ
        )
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> ShortcutAction {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if !tap.reenable() {
                scheduler.async { [weak self] in
                    self?.failOpenStop(message: "系统事件钩子被停用，无法恢复。所有按键已放行。")
                }
            }
            return .pass
        }
        guard let snapshot = ShortcutKeyClassifier.snapshot(type: type, event: event) else {
            return .pass
        }
        let step = process(snapshot)
        if case .rewriteOptionCommandV = step.action,
           let flags = ShortcutEventApplicator.flags(for: step.action, current: event.flags) {
            event.flags = flags
        }
        perform(step.effect)
        return step.action
    }

    private func perform(_ effect: ShortcutEffect) {
        switch effect {
        case .none:
            break
        case .probeFinderCut:
            scheduler.async { [weak self] in
                self?.runFinderCutProbe()
            }
        case .notifyQuitArmed(let name, let finderDismiss):
            scheduler.async { [weak self] in
                if finderDismiss {
                    self?.alerts.notify(
                        title: "再次按 ⌘Q 强关访达",
                        body: "2 秒内再次按下才会关闭全部窗口并隐藏访达。切换应用或超时后需重新双击。"
                    )
                } else {
                    self?.alerts.notify(
                        title: "再次按 ⌘Q 退出 \(name)",
                        body: "2 秒内再次按下才会退出。切换应用或超时后需重新双击。"
                    )
                }
            }
        case .dismissFinderWindows:
            scheduler.async { [weak self] in
                self?.runFinderDismiss()
            }
        }
    }

    private func runFinderDismiss() {
        guard engine.finderCommandQEnabled else { return }
        switch dismisser.dismissWindowsAndHide() {
        case .success:
            break
        case .failure(.notPermitted):
            alerts.notify(
                title: "无法关闭访达窗口",
                body: "请允许 Tocode 控制访达。未授权时不会隐藏访达。"
            )
        case .failure:
            alerts.notify(
                title: "无法关闭访达窗口",
                body: "关闭窗口失败，访达保持原状。"
            )
        }
    }

    private func runFinderCutProbe() {
        guard engine.finderMoveEnabled, frontmostApps.frontmost()?.isFinder == true else {
            return
        }
        if editingContext.isEditingText() {
            synthesizer.postCommandX()
            return
        }
        let before = pasteboard.changeCount
        synthesizer.postCommandC()
        scheduler.asyncAfter(Self.cutVerifyDelay) { [weak self] in
            self?.verifyCutPreparation(before: before)
        }
    }

    private func verifyCutPreparation(before: Int) {
        guard engine.finderMoveEnabled else { return }
        let after = pasteboard.changeCount
        if after != before && pasteboard.containsFileURLs() {
            engine.armCut(changeCount: after)
        } else {
            engine.clearCut()
        }
    }

    private func failOpenStop(message: String) {
        engine.setFinderMoveEnabled(false)
        engine.setDoubleCommandQEnabled(false)
        engine.setFinderCommandQEnabled(false)
        settings.finderMoveHotkeysEnabled = false
        settings.doubleCommandQEnabled = false
        settings.finderCommandQEnabled = false
        tap.remove()
        alerts.notify(title: "快捷键保护已关闭", body: message)
    }
}

struct SystemShortcutPermissionGate: ShortcutPermissionChecking {
    func hasAccessibilityAccess() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityAccess() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

final class CGEventShortcutTap: ShortcutTapControlling {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: ((CGEventType, CGEvent) -> ShortcutAction)?

    var isInstalled: Bool { port != nil }

    var isEnabled: Bool {
        guard let port else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    func install(handler: @escaping (CGEventType, CGEvent) -> ShortcutAction) -> Bool {
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
            let tap = Unmanaged<CGEventShortcutTap>.fromOpaque(refcon).takeUnretainedValue()
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
        let action = handler?(type, event) ?? .pass
        if action == .suppress {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }
}

struct WorkspaceFrontmostApplication: FrontmostApplicationProviding {
    func frontmost() -> FrontmostAppInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontmostAppInfo(
            pid: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName,
            bundleURL: app.bundleURL
        )
    }
}

struct GeneralFilePasteboard: FilePasteboardReading {
    let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func containsFileURLs() -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: options) {
            return true
        }
        if let names = pasteboard.propertyList(forType: .fileURL) as? [String], !names.isEmpty {
            return true
        }
        let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let names = pasteboard.propertyList(forType: filenames) as? [String], !names.isEmpty {
            return true
        }
        return false
    }
}

/// 无法判断焦点时按文本编辑处理，避免破坏 Finder 重命名或输入框中的剪切。
struct SystemFinderEditingContext: FinderEditingContextChecking {
    func isEditingText() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard error == .success, let focusedRef else {
            return true
        }
        let element = unsafeBitCast(focusedRef, to: AXUIElement.self)
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String
        else {
            return true
        }
        let editingRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        return editingRoles.contains(role)
    }
}

struct SystemShortcutClock: ShortcutClock {
    func now() -> Date { Date() }
}

struct MainQueueShortcutScheduler: ShortcutScheduling {
    func async(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    func asyncAfter(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

struct UserNotificationShortcutAlert: ShortcutAlerting {
    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "tocode.shortcut.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
