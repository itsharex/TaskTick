import ArgumentParser
import Foundation
import TaskTickCore

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start a task. Wakes TaskTick.app if not running."
    )

    @Argument(help: "Task identifier.")
    var identifier: String

    @Flag(name: .long) var json: Bool = false

    @MainActor
    func run() async throws {
        try await dispatch(action: .run, identifier: identifier, json: json)
    }
}

/// Shared dispatch logic for run/stop/restart/reveal — they only differ by
/// CLIAction enum value and the success message verb.
@MainActor
func dispatch(action: NotificationBridge.CLIAction, identifier: String, json: Bool) async throws {
    let store = try ReadOnlyStore()
    let allTasks = try store.fetchTasks()
    let resolver = TaskResolver(
        items: allTasks,
        idOf: { $0.id },
        nameOf: { $0.name },
        serialOf: { $0.serialNumber }
    )

    let task: ScheduledTask
    do {
        task = try resolver.resolve(identifier)
    } catch let err as TaskResolverError {
        FileHandle.standardError.write(Data("tasktick: \(err)\n".utf8))
        throw ExitCode(1)
    }

    // Idempotency: already-running guard for run, idle guard for stop.
    let runningIds = NotificationBridge.runningTaskIds(store: store)
    let isRunning = runningIds.contains(task.id)
    switch action {
    case .run where isRunning:
        FileHandle.standardError.write(Data("note: already running\n".utf8))
        printSuccess(action: action, name: task.name, json: json)
        return
    case .stop where !isRunning:
        FileHandle.standardError.write(Data("note: not running\n".utf8))
        printSuccess(action: action, name: task.name, json: json)
        return
    default:
        break
    }

    if GUILauncher.isRunning() {
        NotificationBridge.post(action: action, taskId: task.id)
    } else {
        // Wake the GUI and let it process the URL Scheme directly.
        let ok = GUILauncher.launchAndWait(action: action, taskId: task.id)
        if !ok {
            FileHandle.standardError.write(Data("tasktick: TaskTick.app failed to launch within 10s\n".utf8))
            throw ExitCode(1)
        }
    }
    printSuccess(action: action, name: task.name, json: json)
}

private func printSuccess(action: NotificationBridge.CLIAction, name: String, json: Bool) {
    if json {
        let payload: [String: String] = [
            "id": action.rawValue,
            "status": {
                switch action {
                case .run: return "started"
                case .stop: return "stopped"
                case .restart: return "restarted"
                case .reveal: return "revealed"
                }
            }(),
            "name": name
        ]
        let data = try? JSONEncoder().encode(payload)
        print(String(data: data ?? Data(), encoding: .utf8) ?? "{}")
    } else {
        let verb: String = {
            switch action {
            case .run: return "Started"
            case .stop: return "Stopped"
            case .restart: return "Restarted"
            case .reveal: return "Revealed in TaskTick"
            }
        }()
        print("✓ \(verb): \(name)")
    }
}
