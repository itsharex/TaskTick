import SwiftUI
import SwiftData

/// Content view displayed in the menu bar popover.
struct MenuBarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \ScheduledTask.createdAt, order: .reverse) private var tasks: [ScheduledTask]
    @StateObject private var scheduler = TaskScheduler.shared
    /// Watching the live settings object so the shortcut hint here updates the
    /// instant the user re-records it in Settings — no stale label.
    @ObservedObject private var quickLauncherSettings = QuickLauncherSettings.shared

    var upcomingTasks: [ScheduledTask] {
        tasks
            .filter { $0.isEnabled && !$0.isManualOnly && $0.nextRunAt != nil }
            .sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
            .prefix(5)
            .map { $0 }
    }

    var manualTasks: [ScheduledTask] {
        tasks
            .filter { $0.isEnabled && $0.isManualOnly }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(.tint)
                Text(L10n.tr("app.name"))
                    .font(.headline)
                Spacer()
                Text("\(tasks.filter(\.isEnabled).count)/\(tasks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Task list
            if upcomingTasks.isEmpty && manualTasks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.quaternary)
                    Text(L10n.tr("menubar.no_tasks"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 2) {
                    if !upcomingTasks.isEmpty {
                        HStack {
                            Text(L10n.tr("menubar.upcoming"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 4)

                        ForEach(upcomingTasks) { task in
                            MenuBarTaskRow(task: task, isRunning: scheduler.runningTaskIDs.contains(task.id))
                        }
                    }

                    if !manualTasks.isEmpty {
                        HStack {
                            Text(L10n.tr("menubar.manual_scripts"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, upcomingTasks.isEmpty ? 4 : 8)

                        ForEach(manualTasks) { task in
                            MenuBarTaskRow(task: task, isRunning: scheduler.runningTaskIDs.contains(task.id))
                        }
                    }
                }
                .padding(8)
            }

            Divider()

            // Footer actions
            VStack(spacing: 0) {
                // Open main window
                Button(action: {
                    // Dismiss the MenuBarExtra panel
                    if let panel = NSApp.keyWindow as? NSPanel {
                        panel.orderOut(nil)
                    }

                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "main")

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        for window in NSApp.windows where window.canBecomeMain && !(window is NSPanel) {
                            window.makeKeyAndOrderFront(nil)
                            break
                        }
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }) {
                    HStack {
                        Text(L10n.tr("menubar.open"))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Divider().padding(.horizontal, 12)

                // Quick Launcher (only when enabled in Settings)
                if quickLauncherSettings.isEnabled {
                    Button(action: {
                        if let panel = NSApp.keyWindow as? NSPanel {
                            panel.orderOut(nil)
                        }
                        QuickLauncherController.shared.toggle()
                    }) {
                        HStack(spacing: 6) {
                            Text(L10n.tr("quick_launcher.menu_item"))
                            Spacer()
                            // 1Password-style: each modifier and the key get
                            // their own kbd pill so the shortcut is legible
                            // at a glance.
                            ForEach(quickLauncherSettings.displayChips, id: \.self) { chip in
                                Text(chip)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.primary.opacity(0.85))
                                    .frame(minWidth: 16)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Color.primary.opacity(0.10))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3)
                                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                                    )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Divider().padding(.horizontal, 12)
                }

                // Check for updates
                Button(action: {
                    Task { await UpdateChecker.shared.checkForUpdates(userInitiated: true) }
                }) {
                    HStack {
                        Text(L10n.tr("command.check_updates"))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Divider().padding(.horizontal, 12)

                // Quit
                Button(action: {
                    AppDelegate.shouldReallyQuit = true
                    NSApp.terminate(nil)
                }) {
                    HStack {
                        Text(L10n.tr("menubar.quit"))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.vertical, 4)
        }
        .frame(width: 300)
        .onAppear {
            if !scheduler.isRunning {
                scheduler.configure(modelContext: modelContext)
                scheduler.start()
            }
        }
    }
}

struct MenuBarTaskRow: View {
    @Environment(\.modelContext) private var modelContext
    let task: ScheduledTask
    let isRunning: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isRunning ? .blue : (task.isEnabled ? .green : .gray.opacity(0.4)))
                .frame(width: 8, height: 8)

            Text(task.name)
                .font(.system(.body, design: .default))
                .lineLimit(1)

            Spacer()

            if isRunning {
                if isHovering {
                    Button {
                        ScriptExecutor.shared.cancel(taskId: task.id)
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(L10n.tr("task.detail.stop"))
                } else {
                    ProgressView()
                        .controlSize(.mini)
                }
            } else if isHovering {
                Button {
                    Task {
                        _ = await ScriptExecutor.shared.execute(task: task, modelContext: modelContext)
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            } else if task.isManualOnly {
                Image(systemName: "play.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if let nextRun = task.nextRunAt {
                Text(nextRun, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isHovering ? 0.05 : 0.00001))
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
