import AppKit
import Foundation

protocol MacTimerControlling: AnyObject {
    var timers: [MacTimer] { get }
    var onChange: (() -> Void)? { get set }
    func applySavedSettings()
    func shutdown()
    func handleWake()
    @discardableResult
    func saveAndStart(
        _ draft: MacTimerDraft
    ) -> Result<MacTimer, MacTimerValidationError>
    func delete(id: UUID)
}

/// 按最近到期时刻调度；一次性到点后停用，cron 到点后续排。
final class MacTimerService: MacTimerControlling {
    private let store: MacTimerStore
    private let clock: ShortcutClock
    private let scheduler: ShortcutScheduling
    private let calendar: Calendar
    private var scheduleGeneration = 0
    private var wakeObserver: NSObjectProtocol?
    private(set) var timers: [MacTimer] = []

    /// 到点执行事项（主线程回调）。
    var fireHandler: ((KeyboardShortcutMappingTarget) -> Void)?
    /// 任务列表或运行态变化时通知菜单刷新。
    var onChange: (() -> Void)?

    init(
        store: MacTimerStore = MacTimerStore(),
        clock: ShortcutClock = SystemShortcutClock(),
        scheduler: ShortcutScheduling = MainQueueShortcutScheduler(),
        calendar: Calendar = .current
    ) {
        self.store = store
        self.clock = clock
        self.scheduler = scheduler
        self.calendar = calendar
    }

    func applySavedSettings() {
        timers = store.allTimers()
        // 冷启动：已过点不补执行；一次性停用，cron 重算下次。
        clearDue(execute: false)
        installWakeObserver()
        scheduleNext()
    }

    func shutdown() {
        scheduleGeneration += 1
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    func handleWake() {
        clearDue(execute: true)
        scheduleNext()
    }

    @discardableResult
    func saveAndStart(
        _ draft: MacTimerDraft
    ) -> Result<MacTimer, MacTimerValidationError> {
        switch store.saveAndStart(draft, now: clock.now(), calendar: calendar) {
        case .success(let saved):
            timers = store.allTimers()
            scheduleNext()
            onChange?()
            return .success(saved)
        case .failure(let error):
            return .failure(error)
        }
    }

    func delete(id: UUID) {
        store.delete(id: id)
        timers = store.allTimers()
        scheduleNext()
        onChange?()
    }

    /// 测试或手动推进：检查已到期任务。
    func checkDueForTesting() {
        clearDue(execute: true)
        scheduleNext()
    }

    private func installWakeObserver() {
        if wakeObserver != nil { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    private func scheduleNext() {
        scheduleGeneration += 1
        let generation = scheduleGeneration
        guard let next = timers.compactMap(\.fireAt).min() else { return }
        let delay = max(0, next.timeIntervalSince(clock.now()))
        scheduler.asyncAfter(delay) { [weak self] in
            guard let self, self.scheduleGeneration == generation else { return }
            self.clearDue(execute: true)
            self.scheduleNext()
        }
    }

    private func clearDue(execute: Bool) {
        let now = clock.now()
        var changed = false
        var dueTargets: [KeyboardShortcutMappingTarget] = []
        for index in timers.indices {
            guard let fireAt = timers[index].fireAt, fireAt <= now else { continue }
            changed = true
            if execute {
                dueTargets.append(timers[index].target)
            }
            switch timers[index].kind {
            case .once:
                timers[index].fireAt = nil
            case .cron:
                if let expression = timers[index].cronExpression,
                   let schedule = MacCronSchedule.parse(expression),
                   let next = schedule.nextFire(after: now, calendar: calendar)
                {
                    timers[index].fireAt = next
                } else {
                    timers[index].fireAt = nil
                }
            }
        }
        guard changed else { return }
        store.replaceAll(timers)
        if execute {
            for target in dueTargets {
                fireHandler?(target)
            }
        }
        onChange?()
    }
}
