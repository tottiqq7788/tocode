import Foundation

struct MacTimer: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var durationMinutes: Int
    var target: KeyboardShortcutMappingTarget
    /// 非 nil 表示运行中；到点或停用后清为 nil（未启动）。
    var fireAt: Date?

    var isRunning: Bool { fireAt != nil }
}

struct MacTimerDraft: Equatable {
    var id: UUID?
    var name: String
    var durationMinutesText: String
    var target: KeyboardShortcutMappingTarget?

    init(
        id: UUID? = nil,
        name: String = "",
        durationMinutesText: String = "",
        target: KeyboardShortcutMappingTarget? = nil
    ) {
        self.id = id
        self.name = name
        self.durationMinutesText = durationMinutesText
        self.target = target
    }

    init(timer: MacTimer) {
        id = timer.id
        name = timer.name
        durationMinutesText = String(timer.durationMinutes)
        target = timer.target
    }
}

enum MacTimerValidationError: Error, Equatable, LocalizedError {
    case emptyName
    case invalidDuration
    case missingTarget
    case duplicateName
    case timerNotFound

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "请输入名称。"
        case .invalidDuration:
            return "请输入 1 到 10080 之间的整数分钟。"
        case .missingTarget:
            return "请配置要执行的事项。"
        case .duplicateName:
            return "该名称已存在，请使用其他名称。"
        case .timerNotFound:
            return "该定时任务已不存在，请重新打开定时器菜单。"
        }
    }
}

enum MacTimerRemaining {
    static let minMinutes = 1
    static let maxMinutes = 10080

    static func parseMinutes(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= minMinutes, value <= maxMinutes else {
            return nil
        }
        return value
    }

    static func format(seconds remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    static func menuTitle(name: String, fireAt: Date?, now: Date) -> String {
        guard let fireAt else { return name }
        let remaining = fireAt.timeIntervalSince(now)
        guard remaining > 0 else { return name }
        return "\(name) · 剩余 \(format(seconds: remaining))"
    }
}

struct MacTimerStore {
    static let defaultsKey = "tocode.macTimers"

    let defaults: UserDefaults

    init(defaults: UserDefaults = TocodePreferences.shared) {
        self.defaults = defaults
    }

    func allTimers() -> [MacTimer] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([MacTimer].self, from: data)) ?? []
    }

    func replaceAll(_ timers: [MacTimer]) {
        let data = try? JSONEncoder().encode(timers)
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func saveAndStart(
        _ draft: MacTimerDraft,
        now: Date
    ) -> Result<MacTimer, MacTimerValidationError> {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyName) }
        guard let minutes = MacTimerRemaining.parseMinutes(draft.durationMinutesText) else {
            return .failure(.invalidDuration)
        }
        guard let target = draft.target else { return .failure(.missingTarget) }

        var timers = allTimers()
        let others = timers.filter { $0.id != draft.id }
        if others.contains(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return .failure(.duplicateName)
        }

        let fireAt = now.addingTimeInterval(TimeInterval(minutes * 60))
        if let id = draft.id {
            guard let index = timers.firstIndex(where: { $0.id == id }) else {
                return .failure(.timerNotFound)
            }
            timers[index].name = name
            timers[index].durationMinutes = minutes
            timers[index].target = target
            timers[index].fireAt = fireAt
            replaceAll(timers)
            return .success(timers[index])
        }

        let created = MacTimer(
            id: UUID(),
            name: name,
            durationMinutes: minutes,
            target: target,
            fireAt: fireAt
        )
        timers.append(created)
        replaceAll(timers)
        return .success(created)
    }

    func delete(id: UUID) {
        replaceAll(allTimers().filter { $0.id != id })
    }
}
