import AppKit
import SwiftUI
import TaskTickCore

/// Settings → Command Line section. Detects whether the `tasktick` symlink
/// already points at the current .app, and offers a one-shot dialog with
/// the sudo command pre-filled (1Password 7 pattern).
struct CLIInstallSection: View {

    @State private var installState: InstallState = .unknown

    enum InstallState: Equatable {
        case unknown
        case installed(path: String)
        case notInstalled
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("settings.cli.description"))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button(L10n.tr("settings.cli.enable_button")) {
                        showEnableDialog()
                    }

                    statusLabel
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text(L10n.tr("settings.cli.section.title"))
        }
        .onAppear { refreshState() }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch installState {
        case .unknown:
            EmptyView()
        case .installed(let path):
            Label(L10n.tr("settings.cli.installed", path), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .notInstalled:
            Label(L10n.tr("settings.cli.not_installed"), systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    private func refreshState() {
        // Candidate symlink locations, Apple Silicon path first.
        let candidates = ["/opt/homebrew/bin/tasktick", "/usr/local/bin/tasktick"]
        // The CLI binary the user should symlink to. Resolve from the running
        // GUI's own executable path so this stays correct regardless of
        // whether the user installed to /Applications, ~/Applications, or a
        // custom location.
        let cliInBundle = currentAppCLIPath()
        for path in candidates {
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
               target == cliInBundle {
                installState = .installed(path: path)
                return
            }
        }
        installState = .notInstalled
    }

    /// Path to the `tasktick` binary co-located with the running GUI.
    /// Bundle.main.bundleURL is the .app root; the CLI is at
    /// Contents/MacOS/tasktick.
    private func currentAppCLIPath() -> String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/tasktick")
            .path
    }

    private func showEnableDialog() {
        // Prefer Homebrew prefix on Apple Silicon if it exists; fall back to /usr/local/bin.
        let target = FileManager.default.fileExists(atPath: "/opt/homebrew/bin")
            ? "/opt/homebrew/bin/tasktick"
            : "/usr/local/bin/tasktick"
        let cliPath = currentAppCLIPath()
        let cmd = "sudo ln -sf \"\(cliPath)\" \(target)"

        let alert = NSAlert()
        alert.messageText = L10n.tr("settings.cli.install.alert.title")
        alert.informativeText = L10n.tr("settings.cli.install.alert.message", cmd)
        alert.addButton(withTitle: L10n.tr("settings.cli.install.alert.copy"))
        alert.addButton(withTitle: L10n.tr("settings.cli.install.alert.open_terminal"))
        alert.addButton(withTitle: L10n.tr("settings.cli.install.alert.cancel"))

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
            // Open Terminal so the user can paste immediately.
            if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.open(terminalURL)
            }
        default:
            break
        }
        // Refresh in case the user already ran the command before clicking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            refreshState()
        }
    }
}
