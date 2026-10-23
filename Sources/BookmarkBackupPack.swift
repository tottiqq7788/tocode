import Foundation

struct BookmarkBackupSlot: Codable, Equatable {
    var day: String
    var takenAt: Double
    var ledger: BookmarkLedgerSnapshot
}

struct BookmarkBackupPack: Codable, Equatable {
    var version: Int
    var slots: [BookmarkBackupSlot]
    /// 备份远程房间修订号（本机跟踪；不参与正式账本）。
    var remoteRevision: Int

    static let empty = BookmarkBackupPack(version: 1, slots: [], remoteRevision: 0)
    static let maxSlots = 7
}

enum BookmarkBackupPackLogic {
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayString(from date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    static func parseDay(_ day: String) -> Date? {
        dayFormatter.date(from: day)
    }

    /// 写入/覆盖当日槽后裁剪到「today−6」起共最多 7 日。
    static func upsert(
        pack: BookmarkBackupPack,
        day: String,
        ledger: BookmarkLedgerSnapshot,
        takenAt: Double,
        today: String
    ) -> BookmarkBackupPack {
        var next = pack
        if next.version <= 0 {
            next.version = 1
        }
        let slot = BookmarkBackupSlot(day: day, takenAt: takenAt, ledger: ledger)
        if let index = next.slots.firstIndex(where: { $0.day == day }) {
            next.slots[index] = slot
        } else {
            next.slots.append(slot)
        }
        next.slots = prune(slots: next.slots, today: today)
        return next
    }

    static func prune(slots: [BookmarkBackupSlot], today: String) -> [BookmarkBackupSlot] {
        guard let todayDate = parseDay(today) else {
            return Array(slots.sorted { $0.day < $1.day }.suffix(maxSlots))
        }
        let calendar = Calendar(identifier: .gregorian)
        guard let oldest = calendar.date(byAdding: .day, value: -(maxSlots - 1), to: todayDate) else {
            return Array(slots.sorted { $0.day < $1.day }.suffix(maxSlots))
        }
        let oldestDay = dayString(from: oldest)
        let kept = slots.filter { $0.day >= oldestDay }.sorted { $0.day < $1.day }
        return Array(kept.suffix(maxSlots))
    }

    static var maxSlots: Int { BookmarkBackupPack.maxSlots }

    /// 合并本机与远程备份包：同日以本机槽为准；再按 today 裁剪。
    static func mergePreferringLocal(
        local: BookmarkBackupPack,
        remote: BookmarkBackupPack,
        today: String
    ) -> BookmarkBackupPack {
        var byDay: [String: BookmarkBackupSlot] = [:]
        for slot in remote.slots {
            byDay[slot.day] = slot
        }
        for slot in local.slots {
            byDay[slot.day] = slot
        }
        return BookmarkBackupPack(
            version: max(local.version, remote.version, 1),
            slots: prune(slots: Array(byDay.values), today: today),
            remoteRevision: max(local.remoteRevision, remote.remoteRevision)
        )
    }

    static func slot(in pack: BookmarkBackupPack, day: String?) -> BookmarkBackupSlot? {
        let sorted = pack.slots.sorted { $0.day < $1.day }
        guard let day else {
            return sorted.last
        }
        return sorted.first { $0.day == day }
    }
}
