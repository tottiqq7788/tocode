import CoreGraphics
import Foundation

enum WeChatQuickInputSegment: Equatable {
    case key(raw: String)
    case text(String)
}

enum WeChatQuickInputStep: Equatable {
    case key(RecordedShortcut)
    case text(String)
}

enum WeChatQuickInputError: Equatable, LocalizedError {
    case tooManySegments
    case textTooLong
    case emptyText
    case emptyKey
    case missingPrimary
    case duplicateModifier
    case unknownToken(String)

    var errorDescription: String? {
        switch self {
        case .tooManySegments:
            return "快捷输入最多 16 段"
        case .textTooLong:
            return "快捷输入文字合计不能超过 500 字"
        case .emptyText:
            return "文字段不能为空"
        case .emptyKey:
            return "按键段不能为空"
        case .missingPrimary:
            return "按键段必须恰好一个主键"
        case .duplicateModifier:
            return "按键段含有重复的修饰键"
        case .unknownToken(let token):
            return token.isEmpty ? "无法识别按键" : "无法识别按键：\(token)"
        }
    }
}

enum WeChatQuickInput {
    static let maxSegments = 16
    static let maxTextCount = 500
    static let leftQuote: Character = "\u{201C}"
    static let rightQuote: Character = "\u{201D}"

    static func tokenize(_ raw: String) -> [WeChatQuickInputSegment]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var segments: [WeChatQuickInputSegment] = []
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            while index < trimmed.endIndex, trimmed[index].isWhitespace {
                index = trimmed.index(after: index)
            }
            guard index < trimmed.endIndex else { break }

            let character = trimmed[index]
            if character == leftQuote {
                let innerStart = trimmed.index(after: index)
                guard let close = trimmed[innerStart...].firstIndex(of: rightQuote) else {
                    return nil
                }
                segments.append(.text(String(trimmed[innerStart..<close])))
                index = trimmed.index(after: close)
            } else if character == "{" {
                let innerStart = trimmed.index(after: index)
                guard let close = trimmed[innerStart...].firstIndex(of: "}") else {
                    return nil
                }
                segments.append(.key(raw: String(trimmed[innerStart..<close])))
                index = trimmed.index(after: close)
            } else {
                return nil
            }
        }
        return segments.isEmpty ? nil : segments
    }

    static func compile(
        _ segments: [WeChatQuickInputSegment]
    ) -> Result<[WeChatQuickInputStep], WeChatQuickInputError> {
        guard segments.count <= maxSegments else {
            return .failure(.tooManySegments)
        }
        let textTotal = segments.reduce(into: 0) { total, segment in
            if case .text(let text) = segment {
                total += text.count
            }
        }
        guard textTotal <= maxTextCount else {
            return .failure(.textTooLong)
        }

        var steps: [WeChatQuickInputStep] = []
        for segment in segments {
            switch segment {
            case .text(let text):
                guard !text.isEmpty else { return .failure(.emptyText) }
                steps.append(.text(text))
            case .key(let raw):
                switch parseKey(raw) {
                case .success(let shortcut):
                    steps.append(.key(shortcut))
                case .failure(let error):
                    return .failure(error)
                }
            }
        }
        return .success(steps)
    }

    static func parseKey(_ raw: String) -> Result<RecordedShortcut, WeChatQuickInputError> {
        let parts = raw
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard parts.contains(where: { !$0.isEmpty }) else {
            return .failure(.emptyKey)
        }
        if parts.contains(where: \.isEmpty) {
            return .failure(.unknownToken(""))
        }
        guard let last = parts.last else {
            return .failure(.emptyKey)
        }

        var modifiers: ShortcutModifiers = []
        for part in parts.dropLast() {
            guard let flag = modifier(named: part) else {
                if primary(named: part) != nil {
                    return .failure(.missingPrimary)
                }
                return .failure(.unknownToken(part))
            }
            if modifiers.contains(flag) {
                return .failure(.duplicateModifier)
            }
            modifiers.insert(flag)
        }

        guard let primaryKey = primary(named: last) else {
            if modifier(named: last) != nil {
                return .failure(.missingPrimary)
            }
            return .failure(.unknownToken(last))
        }
        return .success(
            RecordedShortcut(
                keyCode: primaryKey.code,
                modifiers: modifiers,
                keyLabel: primaryKey.label
            )
        )
    }

    private static func modifier(named token: String) -> ShortcutModifiers? {
        switch token {
        case "cmd", "command", "\u{2318}":
            return .command
        case "opt", "option", "alt", "\u{2325}":
            return .option
        case "shift", "\u{21E7}":
            return .shift
        case "ctrl", "control", "\u{2303}":
            return .control
        case "fn":
            return .function
        default:
            return nil
        }
    }

    private static func primary(named token: String) -> (code: UInt16, label: String)? {
        switch token {
        case "space":
            return (49, "Space")
        case "enter", "return":
            return (36, "Enter")
        case "tab":
            return (48, "Tab")
        case "esc", "escape":
            return (53, "Esc")
        case "delete", "backspace":
            return (51, "Delete")
        case "forwarddelete":
            return (117, "Forward Delete")
        case "left":
            return (123, "\u{2190}")
        case "right":
            return (124, "\u{2192}")
        case "down":
            return (125, "\u{2193}")
        case "up":
            return (126, "\u{2191}")
        case "home":
            return (115, "Home")
        case "end":
            return (119, "End")
        case "pageup":
            return (116, "Page Up")
        case "pagedown":
            return (121, "Page Down")
        case "f1": return (122, "F1")
        case "f2": return (120, "F2")
        case "f3": return (99, "F3")
        case "f4": return (118, "F4")
        case "f5": return (96, "F5")
        case "f6": return (97, "F6")
        case "f7": return (98, "F7")
        case "f8": return (100, "F8")
        case "f9": return (101, "F9")
        case "f10": return (109, "F10")
        case "f11": return (103, "F11")
        case "f12": return (111, "F12")
        default:
            break
        }

        if token.count == 1, let character = token.first {
            if character.isLetter, let code = letterKeyCodes[character] {
                return (code, String(character).uppercased())
            }
            if character.isNumber, let code = numberKeyCodes[character] {
                return (code, String(character))
            }
        }
        return nil
    }

    private static let letterKeyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
        "j": 38, "k": 40, "n": 45, "m": 46
    ]

    private static let numberKeyCodes: [Character: UInt16] = [
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
        "7": 26, "8": 28, "9": 25, "0": 29
    ]
}

protocol WeChatUnicodeInjecting {
    func injectUnicode(_ text: String) -> Bool
}

struct SystemWeChatUnicodeInjector: WeChatUnicodeInjecting {
    func injectUnicode(_ text: String) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            return false
        }
        var utf16 = Array(text.utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
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

protocol WeChatQuickInputPerforming {
    func perform(_ segments: [WeChatQuickInputSegment]) -> TocodeCommandResult
}

struct WeChatQuickInputService: WeChatQuickInputPerforming {
    var permissions: ShortcutPermissionChecking
    var poster: TrackpadShortcutEventPosting
    var unicode: WeChatUnicodeInjecting

    init(
        permissions: ShortcutPermissionChecking = SystemShortcutPermissionGate(),
        poster: TrackpadShortcutEventPosting = SystemTrackpadShortcutEventPoster(),
        unicode: WeChatUnicodeInjecting = SystemWeChatUnicodeInjector()
    ) {
        self.permissions = permissions
        self.poster = poster
        self.unicode = unicode
    }

    func perform(_ segments: [WeChatQuickInputSegment]) -> TocodeCommandResult {
        switch WeChatQuickInput.compile(segments) {
        case .failure(let error):
            return .failure(.operationFailed(error.errorDescription ?? "快捷输入无效"))
        case .success(let steps):
            guard permissions.hasAccessibilityAccess() else {
                return .failure(.operationFailed("需要辅助功能权限才能注入快捷输入"))
            }
            for (index, step) in steps.enumerated() {
                let ok: Bool
                switch step {
                case .key(let shortcut):
                    ok = poster.post(shortcut)
                case .text(let text):
                    ok = unicode.injectUnicode(text)
                }
                if !ok {
                    return .failure(.operationFailed("第 \(index + 1) 段注入失败，后续段已停止"))
                }
            }
            return .success(TocodeCommandOutput("已注入快捷输入"))
        }
    }
}
