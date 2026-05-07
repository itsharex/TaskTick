import AppKit
import SwiftData
import SwiftUI

/// Show a modal warning alert for a non-fatal error. Use at sites where we previously
/// swallowed errors with `try?` and the user needs to know the action didn't take effect.
@MainActor
func presentErrorAlert(titleKey: String, messageKey: String, error: Error) {
    let alert = NSAlert()
    alert.messageText = L10n.tr(titleKey)
    alert.informativeText = L10n.tr(messageKey, error.localizedDescription)
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// When true, `NSApp.terminate` actually quits. Otherwise Cmd+Q just closes windows.
    @MainActor static var shouldReallyQuit = false

    private var revealObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.requestPermission()

        // Apply saved appearance mode
        let mode = UserDefaults.standard.string(forKey: "appearanceMode") ?? "system"
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }

        // Wire up the quick launcher's SwiftData container and arm the global
        // hotkey based on persisted settings. Order matters: the controller
        // needs the container BEFORE the hotkey can fire (otherwise the panel
        // would open with no @Query data source).
        Task { @MainActor in
            QuickLauncherController.shared.configure(modelContainer: TaskTickApp._sharedModelContainer)
            QuickLauncherSettings.shared.applyToHotkey()
            cleanupStaleRunningLogs()
        }

        // Quick Launcher's ⌘O posts this notification to ask for the main
        // window to be focused. We listen here (not in MenuBarView) because
        // MenuBarExtra(.window) lazy-instantiates its body — if the user has
        // never clicked the menu bar icon this session, the SwiftUI observer
        // is never wired up and the notification gets dropped.
        revealObserver = NotificationCenter.default.addObserver(
            forName: .revealTaskInMain,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppDelegate.bringMainWindowForward()
            }
        }
    }

    /// Surface the SwiftUI main window. SwiftUI's `Window(id:)` destroys its
    /// NSWindow on close, so we can't just call `makeKeyAndOrderFront` on a
    /// stale reference — we need `openWindow` to resurrect it. The action is
    /// captured by MainWindowView at first appear and stashed in
    /// `WindowOpener.shared`. The activation+raise step runs after a tick so
    /// SwiftUI has time to install the new NSWindow into the window list.
    @MainActor
    static func bringMainWindowForward() {
        NSApp.setActivationPolicy(.regular)
        WindowOpener.shared.openMain?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for window in NSApp.windows where window.canBecomeMain && !(window is NSPanel) {
                window.makeKeyAndOrderFront(nil)
                break
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Finalize logs left in `.running` state by a previous session. These are
    /// phantoms — the actual process exited (or was killed by a crash / quit)
    /// but `ScriptExecutor.execute` never got to write the terminal status.
    /// Without cleanup, the UI keeps showing them as live forever.
    @MainActor
    private func cleanupStaleRunningLogs() {
        let context = TaskTickApp._sharedModelContainer.mainContext
        let runningRaw = ExecutionStatus.running.rawValue
        let descriptor = FetchDescriptor<ExecutionLog>(
            predicate: #Predicate { $0.statusRaw == runningRaw }
        )
        guard let logs = try? context.fetch(descriptor), !logs.isEmpty else { return }

        let now = Date()
        for log in logs {
            log.status = .cancelled
            log.finishedAt = now
            if log.durationMs == nil {
                log.durationMs = Int(now.timeIntervalSince(log.startedAt) * 1000)
            }
        }
        try? context.save()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppDelegate.shouldReallyQuit {
            // Block the quit behind a confirmation when scripts are still
            // running. Without this, dev servers / long-running tasks would be
            // SIGKILLed without warning, sometimes losing in-progress work
            // (uncommitted edits in a watcher script, half-written DB rows, …).
            let runningNames = runningTaskNames()
            if !runningNames.isEmpty, !confirmQuitWithRunningScripts(runningNames) {
                AppDelegate.shouldReallyQuit = false
                return .terminateCancel
            }
            return .terminateNow
        }
        // Cmd+Q: just close all windows instead of quitting
        for window in sender.windows {
            if window.isVisible && window.canBecomeMain {
                window.close()
            }
        }
        NSApp.setActivationPolicy(.accessory)
        return .terminateCancel
    }

    @MainActor
    private func runningTaskNames() -> [String] {
        let runningIDs = TaskScheduler.shared.runningTaskIDs
        guard !runningIDs.isEmpty else { return [] }
        let context = TaskTickApp._sharedModelContainer.mainContext
        guard let tasks = try? context.fetch(FetchDescriptor<ScheduledTask>()) else { return [] }
        return tasks.filter { runningIDs.contains($0.id) }.map(\.name)
    }

    @MainActor
    private func confirmQuitWithRunningScripts(_ names: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.tr("quit.confirm.title")
        let bullets = names.map { "• \($0)" }.joined(separator: "\n")
        alert.informativeText = L10n.tr("quit.confirm.message", names.count) + "\n\n" + bullets
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("quit.confirm.cancel"))
        let quitButton = alert.addButton(withTitle: L10n.tr("quit.confirm.quit"))
        quitButton.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Re-open main window when dock icon is clicked
        if !flag {
            for window in sender.windows {
                if window.canBecomeMain {
                    window.makeKeyAndOrderFront(self)
                    break
                }
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Switch to accessory mode (menu bar only) when all windows are closed
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Kill every running script tree before we exit. Without this, the
        // children get reparented to launchd and survive as orphans —
        // silent dev servers (no stdout writes) would keep running until the
        // next reboot, and TaskTick has no way to find them again on relaunch.
        ScriptExecutor.shared.cancelAll(graceful: 0.3)

        TaskScheduler.shared.stop()
        // Flush pending SwiftData writes to ensure database is consistent on disk.
        // We can't block termination for user input here, but logging gives a trail
        // when a user later reports "my edits vanished after I quit".
        do {
            try TaskTickApp._sharedModelContainer.mainContext.save()
        } catch {
            NSLog("⚠️ Final save on terminate failed: \(error.localizedDescription)")
        }
        // save() writes to the -wal sidecar but does NOT merge it into the main store.
        // If the update installer replaces the .app right after this, a -wal left
        // behind can be orphaned and its contents lost. Force a checkpoint now so
        // the main store is self-contained.
        StoreHardener.checkpoint(at: TaskTickApp._storeURL)
    }
}
