import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum ScriptSource: String, CaseIterable {
    case inline
    case file

    var label: String {
        switch self {
        case .inline: L10n.tr("editor.script.source.inline")
        case .file: L10n.tr("editor.script.source.file")
        }
    }
}

struct TaskEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let task: ScheduledTask?

    // Basic
    @State private var name = ""
    @State private var isEnabled = true

    // Schedule
    @State private var hasDate = true
    @State private var hasTime = true
    @State private var scheduledDate = Date()
    @State private var repeatType: RepeatType = .daily
    @State private var endRepeatType: EndRepeatType = .never
    @State private var endRepeatDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var endRepeatCount = 10

    // Script
    @State private var shell = "/bin/zsh"
    @State private var scriptBody = ""
    @State private var scriptSource: ScriptSource = .inline
    @State private var scriptFilePath = ""
    @State private var workingDirectory = ""
    @State private var timeoutSeconds = 300

    // Notification
    @State private var notifyOnSuccess = false
    @State private var notifyOnFailure = true

    // Tab
    @State private var selectedTab = 0

    var isEditing: Bool { task != nil }

    var canSave: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let hasScript: Bool
        if scriptSource == .inline {
            hasScript = !scriptBody.trimmingCharacters(in: .whitespaces).isEmpty
        } else {
            hasScript = !scriptFilePath.isEmpty && FileManager.default.fileExists(atPath: scriptFilePath)
        }
        return hasName && hasScript
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab bar
                HStack(spacing: 0) {
                    tabButton(L10n.tr("editor.tab.basic"), icon: "doc.text", index: 0)
                    tabButton(L10n.tr("editor.tab.schedule"), icon: "calendar.badge.clock", index: 1)
                    tabButton(L10n.tr("editor.tab.script"), icon: "terminal", index: 2)
                    tabButton(L10n.tr("editor.tab.notification"), icon: "bell", index: 3)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Divider()
                    .padding(.top, 8)

                // Tab content
                ScrollView {
                    Group {
                        switch selectedTab {
                        case 0: basicTab
                        case 1: scheduleTab
                        case 2: scriptTab
                        case 3: notificationTab
                        default: EmptyView()
                        }
                    }
                    .padding(20)
                }
            }
            .frame(minWidth: 520, minHeight: 440)
            .navigationTitle(isEditing ? L10n.tr("editor.title.edit") : L10n.tr("editor.title.new"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("editor.cancel")) { dismiss() }
                        .pointerCursor()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("editor.save")) { save() }
                        .pointerCursor()
                        .disabled(!canSave)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .onAppear(perform: loadTask)
        }
    }

    // MARK: - Tab Button

    private func tabButton(_ title: String, icon: String, index: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedTab = index
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(selectedTab == index ? Color.accentColor : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedTab == index ? Color.accentColor.opacity(0.1) : .clear)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Basic Tab

    private var basicTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(L10n.tr("editor.section.basic"), icon: "doc.text")

            VStack(spacing: 12) {
                LabeledContent(L10n.tr("editor.name")) {
                    TextField(L10n.tr("editor.name.placeholder"), text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                Divider()

                Toggle(L10n.tr("editor.enabled"), isOn: $isEnabled)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        }
    }

    // MARK: - Schedule Tab

    private var scheduleTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(L10n.tr("editor.tab.schedule"), icon: "calendar.badge.clock")

            VStack(spacing: 0) {
                // Date toggle & picker
                HStack {
                    Label(L10n.tr("schedule.date"), systemImage: "calendar")
                    Spacer()
                    Toggle("", isOn: $hasDate)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if hasDate {
                    Divider().padding(.leading, 48)
                    DatePicker("", selection: $scheduledDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }

                Divider()

                // Time toggle & picker
                HStack {
                    Label(L10n.tr("schedule.time"), systemImage: "clock")
                    Spacer()
                    Toggle("", isOn: $hasTime)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if hasTime {
                    Divider().padding(.leading, 48)
                    DatePicker("", selection: $scheduledDate, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }

                Divider()

                // Repeat
                HStack {
                    Label(L10n.tr("schedule.repeat"), systemImage: "repeat")
                    Spacer()
                    Picker("", selection: $repeatType) {
                        ForEach(RepeatType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                // End Repeat (only show when repeating)
                if repeatType != .never {
                    Divider()

                    HStack {
                        Label(L10n.tr("schedule.end_repeat"), systemImage: "arrow.uturn.right.circle")
                        Spacer()
                        Picker("", selection: $endRepeatType) {
                            ForEach(EndRepeatType.allCases, id: \.self) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    if endRepeatType == .onDate {
                        Divider().padding(.leading, 48)
                        DatePicker(L10n.tr("schedule.end_date"), selection: $endRepeatDate, displayedComponents: .date)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    }

                    if endRepeatType == .afterCount {
                        Divider().padding(.leading, 48)
                        LabeledContent(L10n.tr("schedule.end_count")) {
                            HStack(spacing: 6) {
                                TextField("", value: $endRepeatCount, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 60)
                                    .multilineTextAlignment(.trailing)
                                Text(L10n.tr("schedule.times"))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))

            // Next run preview
            if let nextDate = previewNextRun() {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.tint)
                    Text(L10n.tr("cron.next_run", nextDate.formatted(date: .abbreviated, time: .standard)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Script Tab

    private var scriptTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(L10n.tr("editor.section.script"), icon: "terminal")

            VStack(spacing: 12) {
                // Script source picker
                Picker(L10n.tr("editor.script.source"), selection: $scriptSource) {
                    ForEach(ScriptSource.allCases, id: \.self) { source in
                        Text(source.label).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                if scriptSource == .inline {
                    ScriptEditorView(scriptBody: $scriptBody)
                } else {
                    // File picker
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "doc.text")
                                .foregroundStyle(.secondary)
                            if scriptFilePath.isEmpty {
                                Text(L10n.tr("editor.script.no_file"))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text(scriptFilePath)
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button(L10n.tr("editor.script.choose_file")) {
                                chooseFile()
                            }
                            .pointerCursor()
                        }

                        if !scriptFilePath.isEmpty {
                            if let content = try? String(contentsOfFile: scriptFilePath, encoding: .utf8) {
                                Text(content.prefix(500) + (content.count > 500 ? "\n..." : ""))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(.black.opacity(0.03))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(.separator, lineWidth: 0.5)
                                    )
                            }
                        }
                    }
                }

                Divider()

                Picker(L10n.tr("editor.shell"), selection: $shell) {
                    Text("/bin/zsh").tag("/bin/zsh")
                    Text("/bin/bash").tag("/bin/bash")
                    Text("/bin/sh").tag("/bin/sh")
                }

                TextField(L10n.tr("editor.working_dir"), text: $workingDirectory, prompt: Text(L10n.tr("editor.working_dir.placeholder")))

                LabeledContent(L10n.tr("editor.timeout")) {
                    HStack(spacing: 6) {
                        TextField("", value: $timeoutSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                        Text(L10n.tr("editor.timeout.seconds"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        }
    }

    // MARK: - Notification Tab

    private var notificationTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader(L10n.tr("editor.section.notification"), icon: "bell")

            VStack(spacing: 12) {
                Toggle(L10n.tr("editor.notify_success"), isOn: $notifyOnSuccess)
                Divider()
                Toggle(L10n.tr("editor.notify_failure"), isOn: $notifyOnFailure)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .padding(.bottom, 4)
    }

    private func previewNextRun() -> Date? {
        guard hasDate || hasTime else { return nil }
        let tempTask = ScheduledTask()
        tempTask.scheduledDate = scheduledDate
        tempTask.repeatType = repeatType
        tempTask.endRepeatType = endRepeatType
        tempTask.endRepeatDate = endRepeatDate
        tempTask.endRepeatCount = endRepeatCount
        return TaskScheduler.shared.computeNextRunDate(for: tempTask)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .shellScript, .pythonScript,
            .plainText, .sourceCode,
            UTType(filenameExtension: "sh")!,
            UTType(filenameExtension: "zsh") ?? .plainText,
            UTType(filenameExtension: "rb") ?? .plainText,
            UTType(filenameExtension: "js") ?? .plainText,
        ]
        panel.message = L10n.tr("editor.script.choose_file")

        if panel.runModal() == .OK, let url = panel.url {
            scriptFilePath = url.path(percentEncoded: false)
        }
    }

    private func loadTask() {
        guard let task else { return }
        name = task.name
        isEnabled = task.isEnabled
        shell = task.shell
        scriptBody = task.scriptBody
        workingDirectory = task.workingDirectory ?? ""
        timeoutSeconds = task.timeoutSeconds
        notifyOnSuccess = task.notifyOnSuccess
        notifyOnFailure = task.notifyOnFailure
        repeatType = task.repeatType
        endRepeatType = task.endRepeatType
        endRepeatDate = task.endRepeatDate ?? Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
        endRepeatCount = task.endRepeatCount ?? 10

        if let date = task.scheduledDate {
            scheduledDate = date
            hasDate = true
            hasTime = true
        }

        if let filePath = task.scriptFilePath, !filePath.isEmpty {
            scriptSource = .file
            scriptFilePath = filePath
        } else {
            scriptSource = .inline
        }
    }

    private func save() {
        let target = task ?? ScheduledTask()

        target.name = name.trimmingCharacters(in: .whitespaces)
        target.shell = shell
        target.workingDirectory = workingDirectory.isEmpty ? nil : workingDirectory
        target.timeoutSeconds = timeoutSeconds
        target.notifyOnSuccess = notifyOnSuccess
        target.notifyOnFailure = notifyOnFailure
        target.isEnabled = isEnabled
        target.updatedAt = Date()

        // Schedule
        if hasDate || hasTime {
            target.scheduledDate = scheduledDate
        } else {
            target.scheduledDate = nil
        }
        target.repeatType = repeatType
        target.endRepeatType = repeatType == .never ? .never : endRepeatType
        target.endRepeatDate = endRepeatType == .onDate ? endRepeatDate : nil
        target.endRepeatCount = endRepeatType == .afterCount ? endRepeatCount : nil

        // Clear legacy fields
        target.cronExpression = nil
        target.intervalSeconds = nil

        // Script
        if scriptSource == .file {
            target.scriptFilePath = scriptFilePath
            target.scriptBody = ""
        } else {
            target.scriptFilePath = nil
            target.scriptBody = scriptBody
        }

        if isEnabled {
            target.nextRunAt = TaskScheduler.shared.computeNextRunDate(for: target)
        }

        if task == nil {
            modelContext.insert(target)
        }

        try? modelContext.save()
        TaskScheduler.shared.rebuildSchedule()
        dismiss()
    }
}
