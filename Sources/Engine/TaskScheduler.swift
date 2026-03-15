import AppKit
import Foundation
import SwiftData

/// Master timer-based task scheduler.
/// Maintains a single timer that fires at the earliest `nextRunAt` across all enabled tasks.
@MainActor
final class TaskScheduler: ObservableObject {
    @Published var isRunning = false
    @Published var runningTaskIDs: Set<UUID> = []

    private var masterTimer: Timer?
    private var modelContext: ModelContext?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    static let shared = TaskScheduler()

    private init() {}

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func start() {
        guard let modelContext else { return }
        isRunning = true

        // Compute nextRunAt for all enabled tasks that don't have one
        let descriptor = FetchDescriptor<ScheduledTask>(
            predicate: #Predicate { $0.isEnabled }
        )
        if let tasks = try? modelContext.fetch(descriptor) {
            for task in tasks {
                if task.nextRunAt == nil {
                    task.nextRunAt = computeNextRunDate(for: task)
                }
            }
            try? modelContext.save()
        }

        rebuildSchedule()
        setupSleepWakeObservers()
    }

    func stop() {
        masterTimer?.invalidate()
        masterTimer = nil
        isRunning = false
        removeSleepWakeObservers()
    }

    func rebuildSchedule() {
        masterTimer?.invalidate()
        masterTimer = nil

        guard isRunning, let modelContext else { return }

        let descriptor = FetchDescriptor<ScheduledTask>(
            predicate: #Predicate { $0.isEnabled }
        )
        guard let tasks = try? modelContext.fetch(descriptor) else { return }

        // Find the earliest nextRunAt
        let now = Date()
        var earliest: Date?

        for task in tasks {
            guard let nextRun = task.nextRunAt else { continue }
            if nextRun <= now {
                // Task is overdue, execute it now
                fireTask(task)
                continue
            }
            if earliest == nil || nextRun < earliest! {
                earliest = nextRun
            }
        }

        guard let fireDate = earliest else { return }

        let interval = fireDate.timeIntervalSince(now)
        masterTimer = Timer.scheduledTimer(withTimeInterval: max(interval, 0.1), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.timerFired()
            }
        }
    }

    // MARK: - Private

    private func timerFired() {
        guard let modelContext else { return }

        let now = Date()
        let descriptor = FetchDescriptor<ScheduledTask>(
            predicate: #Predicate { $0.isEnabled }
        )
        guard let tasks = try? modelContext.fetch(descriptor) else { return }

        for task in tasks {
            if let nextRun = task.nextRunAt, nextRun <= now {
                fireTask(task)
            }
        }

        rebuildSchedule()
    }

    private func fireTask(_ task: ScheduledTask) {
        let taskId = task.id
        guard !runningTaskIDs.contains(taskId), let modelContext else { return }

        runningTaskIDs.insert(taskId)

        // Increment execution count
        task.executionCount += 1

        // Check end repeat conditions
        let shouldContinue = checkEndRepeat(for: task)

        // Compute next run date before executing
        if shouldContinue {
            task.nextRunAt = computeNextRunDate(for: task, after: Date())
        } else {
            // End condition met, disable the task
            task.nextRunAt = nil
            task.isEnabled = false
        }
        try? modelContext.save()

        Task {
            await ScriptExecutor.shared.execute(task: task, triggeredBy: .schedule, modelContext: modelContext)
            runningTaskIDs.remove(taskId)
            rebuildSchedule()
        }
    }

    /// Check if the task should continue repeating
    private func checkEndRepeat(for task: ScheduledTask) -> Bool {
        // Non-repeating tasks run once
        if task.repeatType == .never {
            return false
        }

        switch task.endRepeatType {
        case .never:
            return true
        case .onDate:
            if let endDate = task.endRepeatDate {
                return Date() < endDate
            }
            return true
        case .afterCount:
            if let maxCount = task.endRepeatCount {
                return task.executionCount < maxCount
            }
            return true
        }
    }

    func computeNextRunDate(for task: ScheduledTask, after date: Date = Date()) -> Date? {
        // Legacy cron support
        if task.schedule == .cron, let expr = task.cronExpression {
            if let cron = try? CronExpression(parsing: expr) {
                return cron.nextFireDate(after: date)
            }
            return nil
        }

        // Legacy interval support
        if task.schedule == .interval, task.scheduledDate == nil {
            if let interval = task.intervalSeconds, interval > 0 {
                return date.addingTimeInterval(TimeInterval(interval))
            }
            return nil
        }

        // New schedule system
        guard let scheduledDate = task.scheduledDate else { return nil }

        let repeatType = task.repeatType
        let calendar = Calendar.current

        // Non-repeating: just the scheduled date if in the future
        if repeatType == .never {
            return scheduledDate > date ? scheduledDate : nil
        }

        // Repeating: find the next occurrence after `date`
        guard let interval = repeatType.calendarInterval else { return nil }

        // If scheduled date is still in the future, use it
        if scheduledDate > date {
            return scheduledDate
        }

        // Compute next occurrence by stepping forward from scheduledDate
        var candidate = scheduledDate
        while candidate <= date {
            guard let next = calendar.date(byAdding: interval.component, value: interval.value, to: candidate) else {
                return nil
            }
            candidate = next
        }

        // Check end conditions
        switch task.endRepeatType {
        case .never:
            return candidate
        case .onDate:
            if let endDate = task.endRepeatDate, candidate > endDate {
                return nil
            }
            return candidate
        case .afterCount:
            if let maxCount = task.endRepeatCount, task.executionCount >= maxCount {
                return nil
            }
            return candidate
        }
    }

    // MARK: - Sleep/Wake

    private func setupSleepWakeObservers() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // After wake, check for missed tasks
                self?.rebuildSchedule()
            }
        }
    }

    private func removeSleepWakeObservers() {
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        wakeObserver = nil
    }
}
