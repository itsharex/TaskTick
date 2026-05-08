import AppKit
import Foundation

/// Detects whether TaskTick.app is running, launches it via URL Scheme if not,
/// and waits up to 10s for it to be ready before returning.
enum GUILauncher {

    /// Bundle IDs to look for. Includes the dev variant so `tasktick` invoked
    /// during development still works against TaskTick Dev.app.
    private static let bundleIds = ["com.lifedever.TaskTick", "com.lifedever.TaskTick.dev"]

    static func isRunning() -> Bool {
        bundleIds.contains { id in
            !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
        }
    }

    /// Launch TaskTick by opening a URL. Used as fallback when the GUI isn't
    /// running and a write command needs to dispatch. Blocks up to 10s for the
    /// app to be running. Returns whether launch succeeded.
    static func launchAndWait(action: NotificationBridge.CLIAction, taskId: UUID, timeout: TimeInterval = 10) -> Bool {
        guard let url = URL(string: "tasktick://\(action.rawValue)?id=\(taskId.uuidString)") else {
            return false
        }
        NSWorkspace.shared.open(url)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}
