import CoreGraphics
import Foundation

enum TrackpadTapGesture: Int, CaseIterable, Codable, Hashable {
    case threeFingerTap = 3
    case fourFingerTap = 4
    case fiveFingerTap = 5

    var title: String {
        switch self {
        case .threeFingerTap:
            return "三指轻点"
        case .fourFingerTap:
            return "四指轻点"
        case .fiveFingerTap:
            return "五指轻点"
        }
    }
}

struct ShortcutModifiers: OptionSet, Codable, Equatable, Hashable {
    let rawValue: UInt8

    static let control = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let shift = ShortcutModifiers(rawValue: 1 << 2)
    static let command = ShortcutModifiers(rawValue: 1 << 3)
    static let function = ShortcutModifiers(rawValue: 1 << 4)

    var eventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.control) { flags.insert(.maskControl) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.command) { flags.insert(.maskCommand) }
        if contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    var symbols: String {
        var value = ""
        if contains(.control) { value += "\u{2303}" }
        if contains(.option) { value += "\u{2325}" }
        if contains(.shift) { value += "\u{21E7}" }
        if contains(.command) { value += "\u{2318}" }
        if contains(.function) { value += "fn " }
        return value
    }
}

struct RecordedShortcut: Codable, Equatable, Hashable {
    let keyCode: UInt16
    let modifiers: ShortcutModifiers
    let keyLabel: String

    var displayName: String {
        modifiers.symbols + keyLabel
    }
}

struct TrackpadShortcutStore {
    private static let keyPrefix = "tocode.trackpadShortcut"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func shortcut(for gesture: TrackpadTapGesture) -> RecordedShortcut? {
        guard let data = defaults.data(forKey: key(for: gesture)) else { return nil }
        return try? JSONDecoder().decode(RecordedShortcut.self, from: data)
    }

    func allShortcuts() -> [TrackpadTapGesture: RecordedShortcut] {
        Dictionary(uniqueKeysWithValues: TrackpadTapGesture.allCases.compactMap { gesture in
            shortcut(for: gesture).map { (gesture, $0) }
        })
    }

    var hasAnyShortcut: Bool {
        TrackpadTapGesture.allCases.contains { shortcut(for: $0) != nil }
    }

    func setShortcut(_ shortcut: RecordedShortcut, for gesture: TrackpadTapGesture) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        defaults.set(data, forKey: key(for: gesture))
    }

    func removeShortcut(for gesture: TrackpadTapGesture) {
        defaults.removeObject(forKey: key(for: gesture))
    }

    private func key(for gesture: TrackpadTapGesture) -> String {
        "\(Self.keyPrefix).\(gesture.rawValue)FingerTap"
    }
}

struct TrackpadTouchSample: Equatable {
    let touchCount: Int
    let timestamp: TimeInterval
    let firstPosition: CGPoint?
}

/// 单设备轻点状态机。只返回完整抬起后的精确三、四、五指轻点。
struct TrackpadTapRecognizer {
    static let minimumDuration: TimeInterval = 0.025
    static let maximumDuration: TimeInterval = 0.45
    static let maximumMovement: CGFloat = 0.065
    static let minimumPeakFrames = 2

    private var startedAt: TimeInterval?
    private var peakFingerCount = 0
    private var peakFrameCount = 0
    private var lastFingerCount = 0
    private var peakStartPosition: CGPoint?
    private var moved = false
    private var invalid = false
    private var partialLiftStarted = false

    mutating func process(_ sample: TrackpadTouchSample) -> TrackpadTapGesture? {
        let count = max(0, sample.touchCount)

        if count == 0 {
            guard let startedAt else {
                reset()
                return nil
            }
            let duration = sample.timestamp - startedAt
            let gesture = TrackpadTapGesture(rawValue: peakFingerCount)
            let isTap =
                !invalid
                && !moved
                && duration >= Self.minimumDuration
                && duration <= Self.maximumDuration
                && peakFrameCount >= Self.minimumPeakFrames
            reset()
            return isTap ? gesture : nil
        }

        if startedAt == nil {
            startedAt = sample.timestamp
            peakFingerCount = count
            peakFrameCount = 1
            lastFingerCount = count
            peakStartPosition = sample.firstPosition
            invalid = count > TrackpadTapGesture.fiveFingerTap.rawValue
            return nil
        }

        if let startedAt, sample.timestamp - startedAt > Self.maximumDuration {
            invalid = true
        }
        if count > TrackpadTapGesture.fiveFingerTap.rawValue {
            invalid = true
        }

        if count < lastFingerCount {
            partialLiftStarted = true
        } else if partialLiftStarted && count > lastFingerCount {
            invalid = true
        }

        if count > peakFingerCount {
            peakFingerCount = count
            peakFrameCount = 1
            peakStartPosition = sample.firstPosition
        } else if count == peakFingerCount {
            peakFrameCount += 1
            if let start = peakStartPosition, let current = sample.firstPosition {
                let dx = current.x - start.x
                let dy = current.y - start.y
                let limit = Self.maximumMovement * Self.maximumMovement
                if dx * dx + dy * dy > limit {
                    moved = true
                }
            }
        }

        lastFingerCount = count
        return nil
    }

    mutating func reset() {
        startedAt = nil
        peakFingerCount = 0
        peakFrameCount = 0
        lastFingerCount = 0
        peakStartPosition = nil
        moved = false
        invalid = false
        partialLiftStarted = false
    }
}
