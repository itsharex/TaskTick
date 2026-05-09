import AppKit
import Foundation
import TaskTickCore

/// Launch-time check + repair for the user's `tasktick` symlink.
///
/// Background: v1.8.0/1.8.1 release scripts placed the CLI binary at
/// `.app/Contents/MacOS/tasktick`, which silently collided with the GUI
/// binary `TaskTick` on default case-insensitive APFS. v1.8.2 moves the
/// CLI to `Contents/cli/tasktick`, but DMG users who already ran the
/// "Enable CLI" flow on a prior version are left with a symlink pointing
/// at the old (now nonexistent or wrong) path. This module detects that
/// state on app launch and offers a one-click in-place repair via
/// `osascript … with administrator privileges` (a single Touch ID /
/// password prompt — no Settings navigation, no Terminal copy-paste).
@MainActor
enum CLISymlinkRepair {

    /// Standard PATH locations where the user might have installed the
    /// `tasktick` symlink. Apple-Silicon Homebrew first.
    private static let candidatePaths = [
        "/opt/homebrew/bin/tasktick",
        "/usr/local/bin/tasktick"
    ]

    /// Run on `applicationDidFinishLaunching`. No-op for dev builds and
    /// when no broken symlink exists.
    static func checkAndRepairIfNeeded() {
        guard !BundleContext.isDev else { return }

        // The CLI inside the running .app — what the symlink should resolve to.
        let expected = Bundle.main.bundleURL
            .appendingPathComponent("Contents/cli/tasktick")
            .path
        guard FileManager.default.fileExists(atPath: expected) else {
            // CLI not bundled (e.g. swift run directly) — nothing to repair against.
            return
        }

        for path in candidatePaths {
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
                continue
            }
            if target != expected {
                promptRepair(symlinkPath: path, expected: expected)
                return // One prompt per launch; user can repeat next launch if multiple paths broken.
            }
        }
    }

    private static func promptRepair(symlinkPath: String, expected: String) {
        // Don't nag — user can defer per app version.
        let dismissKey = "cliRepair.dismissedVersion"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        if UserDefaults.standard.string(forKey: dismissKey) == version {
            return
        }

        let alert = NSAlert()
        alert.messageText = L10n.tr("cli.repair.title")
        alert.informativeText = L10n.tr("cli.repair.message", symlinkPath)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("cli.repair.update_button"))
        alert.addButton(withTitle: L10n.tr("cli.repair.later_button"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            performRepair(symlinkPath: symlinkPath, expected: expected)
        } else {
            UserDefaults.standard.set(version, forKey: dismissKey)
        }
    }

    private static func performRepair(symlinkPath: String, expected: String) {
        // Single auth prompt via AppleScript admin escalation. -n forces
        // ln to overwrite the existing symlink without de-referencing it.
        let script = """
        do shell script "ln -sfn '\(expected)' '\(symlinkPath)'" with administrator privileges
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                NSLog("✓ CLI symlink repaired: \(symlinkPath) → \(expected)")
                showSuccess(symlinkPath: symlinkPath)
            } else {
                NSLog("⚠️ osascript exited \(task.terminationStatus) during CLI repair")
                // User likely cancelled the auth prompt. Don't dismiss for the
                // version — they may try again next launch.
            }
        } catch {
            NSLog("⚠️ CLI symlink repair failed: \(error)")
        }
    }

    private static func showSuccess(symlinkPath: String) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("cli.repair.success.title")
        alert.informativeText = L10n.tr("cli.repair.success.message", symlinkPath)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
