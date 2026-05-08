import AppKit
import Foundation
import SwiftData
import TaskTickCore

/// Single entry point for CLI / URL-Scheme triggered actions. Both the
/// AppDelegate URL handler and the DistributedNotification observers route
/// here so the action vocabulary lives in exactly one place.
@MainActor
final class CLIBridge {

    static let shared = CLIBridge()

    enum Action: String {
        case run, stop, restart, reveal
    }

    /// Notification names: see spec §6.1
    /// Dynamic per-bundle so dev (`com.lifedever.TaskTick.dev`) and release
    /// (`com.lifedever.TaskTick`) running in parallel don't crosstalk.
    private static var bundlePrefix: String {
        Bundle.main.bundleIdentifier ?? "com.lifedever.TaskTick"
    }

    static var runNotification: Notification.Name     { Notification.Name("\(bundlePrefix).cli.run") }
    static var stopNotification: Notification.Name    { Notification.Name("\(bundlePrefix).cli.stop") }
    static var restartNotification: Notification.Name { Notification.Name("\(bundlePrefix).cli.restart") }
    static var revealNotification: Notification.Name  { Notification.Name("\(bundlePrefix).cli.reveal") }

    private var modelContainer: ModelContainer?

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        registerObservers()
    }

    /// Called by AppDelegate.application(_:open:) on URL Scheme launches and
    /// by DistributedNotification observers below. Idempotent — safe to call
    /// the same action twice.
    func handle(action: Action, taskId: UUID) {
        guard let container = modelContainer else {
            NSLog("⚠️ CLIBridge: handle(\(action.rawValue)) called before configure()")
            return
        }
        let context = container.mainContext
        let descriptor = FetchDescriptor<ScheduledTask>(predicate: #Predicate { $0.id == taskId })
        guard let task = try? context.fetch(descriptor).first else {
            NSLog("⚠️ CLIBridge: no task with id \(taskId)")
            return
        }

        switch action {
        case .run:
            // Already-running guard — match Quick Launcher's idempotent contract.
            guard !TaskScheduler.shared.runningTaskIDs.contains(task.id) else { return }
            Task { _ = await ScriptExecutor.shared.execute(task: task, modelContext: context) }
        case .stop:
            ScriptExecutor.shared.cancel(taskId: task.id)
        case .restart:
            let wasRunning = TaskScheduler.shared.runningTaskIDs.contains(task.id)
            if wasRunning { ScriptExecutor.shared.cancel(taskId: task.id) }
            Task {
                if wasRunning { try? await Task.sleep(for: .milliseconds(200)) }
                _ = await ScriptExecutor.shared.execute(task: task, modelContext: context)
            }
        case .reveal:
            MainWindowSelection.shared.taskToReveal = task
            NotificationCenter.default.post(name: .revealTaskInMain, object: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Parse `tasktick://run?id=<uuid>` into (action, uuid). Returns nil for
    /// malformed URLs.
    func parse(url: URL) -> (action: Action, taskId: UUID)? {
        guard url.scheme == "tasktick",
              let host = url.host,
              let action = Action(rawValue: host),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let idItem = comps.queryItems?.first(where: { $0.name == "id" }),
              let idString = idItem.value,
              let uuid = UUID(uuidString: idString) else {
            return nil
        }
        return (action, uuid)
    }

    // MARK: - DistributedNotification observers

    private func registerObservers() {
        let center = DistributedNotificationCenter.default()
        let table: [(Notification.Name, Action)] = [
            (Self.runNotification,     .run),
            (Self.stopNotification,    .stop),
            (Self.restartNotification, .restart),
            (Self.revealNotification,  .reveal)
        ]
        for (name, action) in table {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let idString = note.userInfo?["id"] as? String,
                      let uuid = UUID(uuidString: idString) else { return }
                Task { @MainActor in self?.handle(action: action, taskId: uuid) }
            }
        }
    }
}
