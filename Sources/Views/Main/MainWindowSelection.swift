import Foundation

/// One-shot rendezvous so external triggers (Quick Launcher, Menu Bar, future
/// URL handlers) can ask the main window to focus a specific task. The main
/// window reads this on appear and on change, then clears it so a later
/// re-appear doesn't re-apply a stale selection.
@MainActor
final class MainWindowSelection: ObservableObject {
    static let shared = MainWindowSelection()
    private init() {}

    @Published var taskToReveal: ScheduledTask?
}

extension Notification.Name {
    /// Posted by the Quick Launcher when the user hits ⌘O. The MenuBarExtra
    /// scene listens because it's always loaded and has `openWindow` in its
    /// environment — non-Scene SwiftUI hosts (the launcher's NSPanel) can't
    /// invoke `openWindow` directly.
    static let revealTaskInMain = Notification.Name("TaskTick.revealTaskInMain")
}
