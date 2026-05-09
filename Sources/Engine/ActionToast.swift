import Foundation
import TaskTickCore

/// Single entry point for "user just performed an action" banners.
/// Run/Stop/Restart success → fires UN banner. Reveal does NOT fire.
/// Failures (CLIBridge couldn't resolve a task etc.) also fire.
enum ActionToast {

    enum Event {
        case started(taskName: String)
        case stopped(taskName: String)
        case restarted(taskName: String)
        case failed(taskName: String?, reason: String)
    }

    /// Globally toggle action banners. Reuses the existing
    /// `notificationsEnabled` UserDefaults key — when the user has turned
    /// off notifications globally, we honor that.
    static func notify(_ event: Event) {
        let enabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        guard enabled else { return }
        let (title, body) = previewContent(for: event)
        NotificationManager.shared.sendNotification(title: title, body: body)
    }

    /// Pure helper used by tests — renders the strings without sending.
    static func previewContent(for event: Event) -> (title: String, body: String) {
        switch event {
        case .started(let name):
            return (L10n.tr("toast.action.started"), name)
        case .stopped(let name):
            return (L10n.tr("toast.action.stopped"), name)
        case .restarted(let name):
            return (L10n.tr("toast.action.restarted"), name)
        case .failed(let name, let reason):
            let body = name.map { "\($0): \(reason)" } ?? reason
            return (L10n.tr("toast.action.failed"), body)
        }
    }
}
