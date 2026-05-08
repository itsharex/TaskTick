import AppKit
import Carbon.HIToolbox
import SwiftUI
import TaskTickCore

/// Click-to-record hotkey field. While recording, an `NSEvent` local monitor
/// intercepts the next key press and saves the (keyCode, modifiers) pair.
/// Until the user records a chord, modifier-only presses are ignored — we
/// require an actual character/function key to commit the binding.
struct HotkeyRecorderView: View {
    @ObservedObject var settings: QuickLauncherSettings
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggleRecording) {
            HStack(spacing: 6) {
                if isRecording {
                    Text(L10n.tr("quick_launcher.recording"))
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    Text(settings.displayString)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .frame(minWidth: 100)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isRecording ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isRecording ? Color.accentColor : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        // Disable the live hotkey while recording so the user can press the
        // current binding without TaskTick's launcher hijacking the keystroke.
        // Settings.applyToHotkey() runs again when recording stops.
        GlobalHotkey.shared.unregister()

        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handleEvent(event)
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
        // Re-arm the global hotkey with the latest binding — covers both the
        // "user committed a new combo" and "user clicked away without
        // recording" cases.
        settings.applyToHotkey()
    }

    private func handleEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            // Need at least one modifier + a printable/function key. A bare
            // letter would conflict with everyday typing in any focused field.
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !modifiers.isEmpty else { return event }
            settings.keyCode = Int(event.keyCode)
            settings.modifiers = modifiers
            stopRecording()
            return nil // swallow the event
        case .flagsChanged:
            // Keep waiting — modifier-only events shouldn't commit a binding.
            return nil
        default:
            return event
        }
    }
}
