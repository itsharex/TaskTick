import AppKit
import SwiftUI

/// A floating panel that displays full script output for strong reminders.
/// User must click "OK" to dismiss.
@MainActor
final class StrongReminderPanel {

    static let shared = StrongReminderPanel()

    private var panel: NSPanel?

    private init() {}

    func show(taskName: String, output: String, durationMs: Int?) {
        dismiss()

        let content = StrongReminderView(
            taskName: taskName,
            output: output,
            durationMs: durationMs,
            onDismiss: { [weak self] in self?.dismiss() }
        )

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 360)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.title = "TaskTick\(L10n.tr("editor.strong_reminder_short")) - \(taskName)"
        panel.animationBehavior = .utilityWindow

        // Position near top-right of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - panel.frame.width - 20
            let y = screenFrame.maxY - panel.frame.height - 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.close()
        panel = nil
    }
}

struct StrongReminderView: View {
    let taskName: String
    let output: String
    let durationMs: Int?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(taskName)
                        .font(.headline)
                    if let ms = durationMs {
                        Text("\(L10n.tr("notification.duration")) \(ms)ms")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(12)

            Divider()

            // Output
            ScrollView {
                Text(output.isEmpty ? L10n.tr("notification.success") : output)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button(L10n.tr("strong_reminder.dismiss")) {
                    onDismiss()
                }
                .keyboardShortcut(.return, modifiers: [])
                .controlSize(.large)
                .pointerCursor()
            }
            .padding(12)
        }
        .frame(width: 420, height: 360)
    }
}
