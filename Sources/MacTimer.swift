import Foundation

enum MacTimerScheduleKind: String, Codable, Equatable {
    case once
    case cron
}

struct MacTimer: Equatable, Identifiable {
    let id: UUID
    var name: String
    var kind: MacTimerScheduleKind
    /// 一次性任务的总分钟数；cron 任务为 0。
    var durationMinutes: Int
    /// cron 表达式；一次性为 nil。
    var cronExpression: String?
    var target: KeyboardShortcutMappingTarget
    /// 非 nil 表示运行中（下次到期时刻）。
    var fireAt: Date?

    var isRunning: Bool { fireAt != nil }
}

extension MacTimer: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, durationMinutes, cronExpression, target, fireAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(MacTimerScheduleKind.self, forKey: .kind) ?? .once
        durationMinutes = try container.decode(Int.self, forKey: .durationMinutes)
        cronExpression = try container.decodeIfPresent(String.self, forKey: .cronExpression)
        target = try container.decode(KeyboardShortcutMappingTarget.self, forKey: .target)
        fireAt = try container.decodeIfPresent(Date.self, forKey: .fireAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(durationMinutes, forKey: .durationMinutes)
        try container.encodeIfPresent(cronExpression, forKey: .cronExpression)
        try container.encode(target, forKey: .target)
        try container.encodeIfPresent(fireAt, forKey: .fireAt)
    }
}

struct MacTimerDraft: Equatable {
    var id: UUID?
    var name: String
    var kind: MacTimerScheduleKind
    var hoursText: String
    var minutesText: String
    var cronExpression: String
    var target: KeyboardShortcutMappingTarget?

    init(
        id: UUID? = nil,
        name: String = "",
        kind: MacTimerScheduleKind = .once,
        hoursText: String = "",
        minutesText: String = "10",
        cronExpression: String = "",
        target: KeyboardShortcutMappingTarget? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.hoursText = hoursText
        self.minutesText = minutesText
        self.cronExpression = cronExpression
        self.target = target
    }

    init(timer: MacTimer) {
        id = timer.id
        name = timer.name
        kind = timer.kind
        switch timer.kind {
        case .once:
            let parts = MacTimerRemaining.splitDuration(timer.durationMinutes)
            hoursText = parts.hours == 0 ? "" : String(parts.hours)
            minutesText = String(parts.minutes)
            cronExpression = ""
        case .cron:
            hoursText = ""
            minutesText = "10"
            cronExpression = timer.cronExpression ?? ""
        }
        target = timer.target
    }
}

enum MacTimerValidationError: Error, Equatable, LocalizedError {
    case emptyName
    case invalidDuration
    case invalidCron
    case missingTarget
    case duplicateName
    case timerNotFound

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "请输入名称。"
        case .invalidDuration:
            return "请填写小时或分钟，合计 1 到 10080 分钟。"
        case .invalidCron:
            return "请输入合法的 5 段 cron 表达式。"
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
    static let maxHours = 168
    static let maxFieldMinutes = 59

    static func splitDuration(_ total: Int) -> (hours: Int, minutes: Int) {
        (total / 60, total % 60)
    }

    /// 空格当 0；两格至少填一格；小时 0…168、分钟 0…59；合计 1…10080。
    static func parseOnceDuration(hoursText: String, minutesText: String) -> Int? {
        let hoursTrimmed = hoursText.trimmingCharacters(in: .whitespacesAndNewlines)
        let minutesTrimmed = minutesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hoursTrimmed.isEmpty || !minutesTrimmed.isEmpty else { return nil }

        let hours: Int
        if hoursTrimmed.isEmpty {
            hours = 0
        } else {
            guard let value = Int(hoursTrimmed), value >= 0, value <= maxHours else { return nil }
            hours = value
        }

        let minutes: Int
        if minutesTrimmed.isEmpty {
            minutes = 0
        } else {
            guard let value = Int(minutesTrimmed), value >= 0, value <= maxFieldMinutes else {
                return nil
            }
            minutes = value
        }

        let total = hours * 60 + minutes
        guard total >= minMinutes, total <= maxMinutes else { return nil }
        return total
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

    static func formatNextFire(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

/// 5 段标准 cron（分 时 日 月 周），本机时区。
struct MacCronSchedule: Equatable {
    let minutes: Set<Int>
    let hours: Set<Int>
    let daysOfMonth: Set<Int>
    let months: Set<Int>
    let daysOfWeek: Set<Int>
    let dayOfMonthWildcard: Bool
    let dayOfWeekWildcard: Bool

    static func parse(_ expression: String) -> MacCronSchedule? {
        let parts = expression
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard parts.count == 5 else { return nil }

        let dayOfMonthWildcard = parts[2] == "*"
        let dayOfWeekWildcard = parts[4] == "*"
        guard
            let minutes = parseField(parts[0], min: 0, max: 59),
            let hours = parseField(parts[1], min: 0, max: 23),
            let daysOfMonth = parseField(parts[2], min: 1, max: 31),
            let months = parseField(parts[3], min: 1, max: 12),
            let daysOfWeek = parseDayOfWeekField(parts[4])
        else {
            return nil
        }

        return MacCronSchedule(
            minutes: minutes,
            hours: hours,
            daysOfMonth: daysOfMonth,
            months: months,
            daysOfWeek: daysOfWeek,
            dayOfMonthWildcard: dayOfMonthWildcard,
            dayOfWeekWildcard: dayOfWeekWildcard
        )
    }

    /// 严格晚于 `now` 的下一分钟起算，两年内找不到则 nil。
    func nextFire(after now: Date, calendar: Calendar = .current) -> Date? {
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: now
        )
        components.second = 0
        components.nanosecond = 0
        guard let floored = calendar.date(from: components),
              let start = calendar.date(byAdding: .minute, value: 1, to: floored)
        else {
            return nil
        }

        let limitMinutes = 2 * 365 * 24 * 60
        var candidate = start
        for _ in 0..<limitMinutes {
            if matches(candidate, calendar: calendar) {
                return candidate
            }
            guard let next = calendar.date(byAdding: .minute, value: 1, to: candidate) else {
                return nil
            }
            candidate = next
        }
        return nil
    }

    func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents(
            [.minute, .hour, .day, .month, .weekday],
            from: date
        )
        guard
            let minute = parts.minute,
            let hour = parts.hour,
            let day = parts.day,
            let month = parts.month,
            let weekday = parts.weekday
        else {
            return false
        }
        // Calendar weekday: 1=Sunday … 7=Saturday → cron 0…6
        let cronWeekday = weekday - 1
        guard minutes.contains(minute), hours.contains(hour), months.contains(month) else {
            return false
        }

        let dayMatches = daysOfMonth.contains(day)
        let weekMatches = daysOfWeek.contains(cronWeekday)
        if dayOfMonthWildcard && dayOfWeekWildcard {
            return true
        }
        if !dayOfMonthWildcard && !dayOfWeekWildcard {
            return dayMatches || weekMatches
        }
        if dayOfMonthWildcard {
            return weekMatches
        }
        return dayMatches
    }

    private static func parseDayOfWeekField(_ field: String) -> Set<Int>? {
        guard let raw = parseField(field, min: 0, max: 7) else { return nil }
        var normalized = Set<Int>()
        for value in raw {
            if value == 7 {
                normalized.insert(0)
            } else if (0...6).contains(value) {
                normalized.insert(value)
            } else {
                return nil
            }
        }
        return normalized
    }

    private static func parseField(_ field: String, min: Int, max: Int) -> Set<Int>? {
        var result = Set<Int>()
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            let token = String(part)
            guard !token.isEmpty else { return nil }
            let pieces = token.split(separator: "/", omittingEmptySubsequences: false)
            let step: Int
            let base: String
            switch pieces.count {
            case 1:
                base = token
                step = 1
            case 2:
                base = String(pieces[0])
                guard let parsedStep = Int(pieces[1]), parsedStep > 0 else { return nil }
                step = parsedStep
            default:
                return nil
            }

            let range: ClosedRange<Int>
            if base == "*" {
                range = min...max
            } else if base.contains("-") {
                let ends = base.split(separator: "-", omittingEmptySubsequences: false)
                guard ends.count == 2,
                      let lower = Int(ends[0]),
                      let upper = Int(ends[1]),
                      lower >= min,
                      upper <= max,
                      lower <= upper
                else {
                    return nil
                }
                range = lower...upper
            } else {
                guard let value = Int(base), value >= min, value <= max else { return nil }
                range = value...value
            }

            var cursor = range.lowerBound
            while cursor <= range.upperBound {
                if cursor >= min && cursor <= max {
                    result.insert(cursor)
                }
                cursor += step
            }
        }
        return result.isEmpty ? nil : result
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
        now: Date,
        calendar: Calendar = .current
    ) -> Result<MacTimer, MacTimerValidationError> {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyName) }
        guard let target = draft.target else { return .failure(.missingTarget) }

        let kind = draft.kind
        let durationMinutes: Int
        let cronExpression: String?
        let fireAt: Date
        switch kind {
        case .once:
            guard let minutes = MacTimerRemaining.parseOnceDuration(
                hoursText: draft.hoursText,
                minutesText: draft.minutesText
            ) else {
                return .failure(.invalidDuration)
            }
            durationMinutes = minutes
            cronExpression = nil
            fireAt = now.addingTimeInterval(TimeInterval(minutes * 60))
        case .cron:
            let expression = draft.cronExpression.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let schedule = MacCronSchedule.parse(expression),
                  let next = schedule.nextFire(after: now, calendar: calendar)
            else {
                return .failure(.invalidCron)
            }
            durationMinutes = 0
            cronExpression = expression
            fireAt = next
        }

        var timers = allTimers()
        let others = timers.filter { $0.id != draft.id }
        if others.contains(where: {
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return .failure(.duplicateName)
        }

        if let id = draft.id {
            guard let index = timers.firstIndex(where: { $0.id == id }) else {
                return .failure(.timerNotFound)
            }
            timers[index].name = name
            timers[index].kind = kind
            timers[index].durationMinutes = durationMinutes
            timers[index].cronExpression = cronExpression
            timers[index].target = target
            timers[index].fireAt = fireAt
            replaceAll(timers)
            return .success(timers[index])
        }

        let created = MacTimer(
            id: UUID(),
            name: name,
            kind: kind,
            durationMinutes: durationMinutes,
            cronExpression: cronExpression,
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
