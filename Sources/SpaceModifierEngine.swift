import Foundation

enum SpaceModifierDecision: Equatable {
    case pass
    case suppress
    case emitSpace
    case passMarkingTotti
}

struct SpaceModifierEvent: Equatable {
    let keyCode: UInt16
    let isKeyDown: Bool
    let isAutoRepeat: Bool
    let isSynthesized: Bool
    /// 空格按下时已经按着的系统修饰键。不含 totti。
    let heldSystemModifiers: ShortcutModifiers
    let time: TimeInterval
}

/// 空格点按与按住的纯状态机。不创建事件钩子，也不写系统修饰键标志。
struct SpaceModifierEngine {
    static let spaceKeyCode: UInt16 = 49
    static let aloneTimeout: TimeInterval = 0.250
    /// "TOTT"。只标记「这颗主键是在 totti 按住期间按下的」，不是合成事件标记。
    static let tottiMarker: Int64 = 0x544F5454

    private var armedAt: TimeInterval?
    private var chorded = false

    mutating func reset() {
        armedAt = nil
        chorded = false
    }

    mutating func process(_ event: SpaceModifierEvent) -> SpaceModifierDecision {
        if event.isSynthesized {
            return .pass
        }
        if event.keyCode == Self.spaceKeyCode {
            return processSpace(event)
        }
        guard armedAt != nil else { return .pass }
        chorded = true
        return .passMarkingTotti
    }

    private mutating func processSpace(_ event: SpaceModifierEvent) -> SpaceModifierDecision {
        if event.isKeyDown {
            if event.isAutoRepeat {
                return armedAt == nil ? .pass : .suppress
            }
            if armedAt != nil {
                return .suppress
            }
            if event.heldSystemModifiers.blocksSpaceModifier {
                return .pass
            }
            armedAt = event.time
            chorded = false
            return .suppress
        }

        guard let armedAt else { return .pass }
        let elapsed = event.time - armedAt
        let shouldEmit = !chorded && elapsed < Self.aloneTimeout
        self.armedAt = nil
        chorded = false
        return shouldEmit ? .emitSpace : .suppress
    }
}

private extension ShortcutModifiers {
    var blocksSpaceModifier: Bool {
        !intersection([.control, .option, .shift, .command]).isEmpty
    }
}
