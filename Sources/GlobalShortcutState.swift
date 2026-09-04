import Foundation
import CoreGraphics

enum ShortcutClassifiedKey: Equatable {
    case commandX
    case commandV
    case commandQ
    case other
}

struct KeyboardEventSnapshot: Equatable {
    var key: ShortcutClassifiedKey
    var isKeyDown: Bool
    var isAutoRepeat: Bool
    var isSynthesized: Bool
    var hasShift: Bool
    var hasOption: Bool
    var hasControl: Bool

    var hasExtraModifiers: Bool {
        hasShift || hasOption || hasControl
    }
}

struct FrontmostAppInfo: Equatable {
    var pid: pid_t
    var bundleIdentifier: String?
    var localizedName: String?
    var bundleURL: URL?

    var isFinder: Bool {
        bundleIdentifier == "com.apple.finder"
    }

    var displayName: String {
        if let localizedName, !localizedName.isEmpty {
            return localizedName
        }
        return "应用"
    }
}

enum ShortcutAction: Equatable {
    case pass
    case suppress
    case rewriteOptionCommandV
}

enum ShortcutEffect: Equatable {
    case none
    case probeFinderCut
    case notifyQuitArmed(appName: String, finderDismiss: Bool)
    case dismissFinderWindows
}

struct ShortcutStep: Equatable {
    var action: ShortcutAction
    var effect: ShortcutEffect = .none

    static let pass = ShortcutStep(action: .pass)
    static let suppress = ShortcutStep(action: .suppress)
}

struct QuitArm: Equatable {
    var pid: pid_t
    var name: String
    var deadline: Date
}

enum ShortcutKeyClassifier {
    static let keyX: Int64 = 7
    static let keyC: Int64 = 8
    static let keyV: Int64 = 9
    static let keyQ: Int64 = 12

    static func snapshot(
        keyCode: Int64,
        flags: CGEventFlags,
        isKeyDown: Bool,
        isAutoRepeat: Bool,
        userData: Int64,
        marker: Int64 = GlobalShortcutEngine.synthesizerMarker
    ) -> KeyboardEventSnapshot {
        let hasCommand = flags.contains(.maskCommand)
        let key: ShortcutClassifiedKey
        if hasCommand {
            switch keyCode {
            case keyX:
                key = .commandX
            case keyV:
                key = .commandV
            case keyQ:
                key = .commandQ
            default:
                key = .other
            }
        } else {
            key = .other
        }
        return KeyboardEventSnapshot(
            key: key,
            isKeyDown: isKeyDown,
            isAutoRepeat: isAutoRepeat,
            isSynthesized: userData == marker,
            hasShift: flags.contains(.maskShift),
            hasOption: flags.contains(.maskAlternate),
            hasControl: flags.contains(.maskControl)
        )
    }

    static func snapshot(type: CGEventType, event: CGEvent) -> KeyboardEventSnapshot? {
        guard type == .keyDown || type == .keyUp else { return nil }
        return snapshot(
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags,
            isKeyDown: type == .keyDown,
            isAutoRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            userData: event.getIntegerValueField(.eventSourceUserData)
        )
    }
}

/// Finder 剪切预备与全局双击 ⌘Q 的纯状态机。不创建钩子、不改剪贴板、不退出应用。
struct GlobalShortcutEngine {
    static let quitWindow: TimeInterval = 2
    static let synthesizerMarker: Int64 = 0x544F4344

    var finderMoveEnabled = false
    var doubleCommandQEnabled = false
    var finderCommandQEnabled = false
    var cutChangeCount: Int?
    var quitArm: QuitArm?
    var rewriteNextCommandVKeyUp = false
    var suppressNextCommandQKeyUp = false

    var isCutPrepared: Bool { cutChangeCount != nil }

    mutating func setFinderMoveEnabled(_ enabled: Bool) {
        finderMoveEnabled = enabled
        if !enabled {
            clearCut()
        }
    }

    mutating func setDoubleCommandQEnabled(_ enabled: Bool) {
        doubleCommandQEnabled = enabled
        if !enabled {
            quitArm = nil
        }
    }

    mutating func setFinderCommandQEnabled(_ enabled: Bool) {
        finderCommandQEnabled = enabled
        if !enabled {
            suppressNextCommandQKeyUp = false
        }
    }

    mutating func clearCut() {
        cutChangeCount = nil
        rewriteNextCommandVKeyUp = false
    }

    mutating func armCut(changeCount: Int) {
        cutChangeCount = changeCount
    }

    mutating func invalidateCutIfNeeded(currentChangeCount: Int) {
        if let armed = cutChangeCount, armed != currentChangeCount {
            clearCut()
        }
    }

    mutating func process(
        _ event: KeyboardEventSnapshot,
        frontmost: FrontmostAppInfo?,
        now: Date,
        pasteboardChangeCount: Int,
        commandQTarget: FrontmostAppInfo? = nil,
        commandQTargetUnknown: Bool = false
    ) -> ShortcutStep {
        invalidateCutIfNeeded(currentChangeCount: pasteboardChangeCount)

        if event.isSynthesized {
            return .pass
        }

        switch event.key {
        case .commandX:
            return processCommandX(event, frontmost: frontmost)
        case .commandV:
            return processCommandV(event, pasteboardChangeCount: pasteboardChangeCount, frontmost: frontmost)
        case .commandQ:
            let target = commandQTargetUnknown ? nil : (commandQTarget ?? frontmost)
            return processCommandQ(event, target: target, now: now)
        case .other:
            return .pass
        }
    }

    private mutating func processCommandX(
        _ event: KeyboardEventSnapshot,
        frontmost: FrontmostAppInfo?
    ) -> ShortcutStep {
        guard finderMoveEnabled, frontmost?.isFinder == true else {
            return .pass
        }
        if event.hasExtraModifiers {
            return .pass
        }
        if event.isAutoRepeat {
            return .suppress
        }
        if event.isKeyDown {
            clearCut()
            return ShortcutStep(action: .suppress, effect: .probeFinderCut)
        }
        return .suppress
    }

    private mutating func processCommandV(
        _ event: KeyboardEventSnapshot,
        pasteboardChangeCount: Int,
        frontmost: FrontmostAppInfo?
    ) -> ShortcutStep {
        if rewriteNextCommandVKeyUp, !event.isKeyDown {
            rewriteNextCommandVKeyUp = false
            return ShortcutStep(action: .rewriteOptionCommandV)
        }
        guard finderMoveEnabled, frontmost?.isFinder == true else {
            return .pass
        }
        if event.hasExtraModifiers {
            return .pass
        }
        guard event.isKeyDown else {
            return .pass
        }
        guard let cut = cutChangeCount, cut == pasteboardChangeCount else {
            return .pass
        }
        rewriteNextCommandVKeyUp = true
        cutChangeCount = nil
        return ShortcutStep(action: .rewriteOptionCommandV)
    }

    private mutating func processCommandQ(
        _ event: KeyboardEventSnapshot,
        target: FrontmostAppInfo?,
        now: Date
    ) -> ShortcutStep {
        if event.hasExtraModifiers {
            return .pass
        }
        if suppressNextCommandQKeyUp, !event.isKeyDown {
            suppressNextCommandQKeyUp = false
            return .suppress
        }
        let anyEnabled = doubleCommandQEnabled || finderCommandQEnabled
        guard anyEnabled else {
            return .pass
        }
        if event.isAutoRepeat {
            return .suppress
        }
        if !event.isKeyDown {
            return quitArm == nil ? .pass : .suppress
        }
        if doubleCommandQEnabled {
            guard let target else {
                return .pass
            }
            if let arm = quitArm, arm.pid == target.pid, now < arm.deadline {
                quitArm = nil
                if finderCommandQEnabled, target.isFinder {
                    suppressNextCommandQKeyUp = true
                    return ShortcutStep(action: .suppress, effect: .dismissFinderWindows)
                }
                return .pass
            }
            quitArm = QuitArm(
                pid: target.pid,
                name: target.displayName,
                deadline: now.addingTimeInterval(Self.quitWindow)
            )
            return ShortcutStep(
                action: .suppress,
                effect: .notifyQuitArmed(
                    appName: target.displayName,
                    finderDismiss: finderCommandQEnabled && target.isFinder
                )
            )
        }
        guard let target, target.isFinder else {
            return .pass
        }
        suppressNextCommandQKeyUp = true
        return ShortcutStep(action: .suppress, effect: .dismissFinderWindows)
    }
}

enum ShortcutEventApplicator {
    static func flags(for action: ShortcutAction, current: CGEventFlags) -> CGEventFlags? {
        switch action {
        case .pass:
            return current
        case .suppress:
            return nil
        case .rewriteOptionCommandV:
            return current.union([.maskCommand, .maskAlternate])
        }
    }
}
