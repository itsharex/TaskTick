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
    @ObservedObject private var editorState = EditorState.shared

    var task: ScheduledTask? { editorState.taskToEdit }

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

    // Custom repeat
    @State private var customIntervalValue = 1
    @State private var customIntervalUnit: CustomRepeatUnit = .day
    @State private var showingCustomRepeat = false

    // Notification
    @State private var notifyOnSuccess = false
    @State private var notifyOnFailure = true

    @State private var selectedTab = 0
    @State private var loadedTaskId: UUID?

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
        TabView(selection: $selectedTab) {
            basicTab
                .tabItem { Label(L10n.tr("editor.tab.basic"), systemImage: "square.and.pencil") }
                .tag(0)

            scheduleTab
                .tabItem { Label(L10n.tr("editor.tab.schedule"), systemImage: "calendar.badge.clock") }
                .tag(1)

            scriptTab
                .tabItem { Label(L10n.tr("editor.tab.script"), systemImage: "terminal") }
                .tag(2)

            notificationTab
                .tabItem { Label(L10n.tr("editor.tab.notification"), systemImage: "bell") }
                .tag(3)
        }
        .frame(width: 500)
        .fixedSize(horizontal: true, vertical: true)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Spacer()
                    Button(L10n.tr("editor.cancel")) {
                        closeWindow()
                    }
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                    Button(L10n.tr("editor.save")) {
                        save()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .pointerCursor()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .onAppear { loadTask() }
        .onChange(of: editorState.taskToEdit?.id) { _, _ in
            loadTask()
        }
    }

    // MARK: - Basic Tab

    private var basicTab: some View {
        Form {
            Section(L10n.tr("editor.section.basic")) {
                TextField(L10n.tr("editor.name"), text: $name, prompt: Text(L10n.tr("editor.name.placeholder")))
                Toggle(L10n.tr("editor.enabled"), isOn: $isEnabled)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Schedule Tab

    private var scheduleTab: some View {
        Form {
            Section(L10n.tr("schedule.date_time")) {
                Toggle(isOn: $hasDate) {
                    Label(L10n.tr("schedule.date"), systemImage: "calendar")
                }

                if hasDate {
                    DatePicker(L10n.tr("schedule.date"), selection: $scheduledDate, displayedComponents: .date)
                        .datePickerStyle(.stepperField)
                }

                Toggle(isOn: $hasTime) {
                    Label(L10n.tr("schedule.time"), systemImage: "clock")
                }

                if hasTime {
                    DatePicker(L10n.tr("schedule.time"), selection: $scheduledDate, displayedComponents: .hourAndMinute)
                }
            }

            Section(L10n.tr("schedule.repeat_section")) {
                Picker(selection: $repeatType) {
                    Text(RepeatType.never.displayName).tag(RepeatType.never)
                    Divider()
                    ForEach(RepeatType.allCases.filter { $0 != .never && $0 != .custom }, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                    Divider()
                    Text(RepeatType.custom.displayName).tag(RepeatType.custom)
                } label: {
                    Label(L10n.tr("schedule.repeat"), systemImage: "repeat")
                }
                .onChange(of: repeatType) { _, newValue in
                    if newValue == .custom {
                        showingCustomRepeat = true
                    }
                }

                if repeatType == .custom {
                    LabeledContent(L10n.tr("repeat.every")) {
                        HStack(spacing: 6) {
                            TextField("", value: $customIntervalValue, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                                .multilineTextAlignment(.center)
                            Picker("", selection: $customIntervalUnit) {
                                ForEach(CustomRepeatUnit.allCases, id: \.self) { unit in
                                    Text(unit.displayName).tag(unit)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 80)
                        }
                    }
                }

                if repeatType != .never {
                    Picker(selection: $endRepeatType) {
                        ForEach(EndRepeatType.allCases, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    } label: {
                        Label(L10n.tr("schedule.end_repeat"), systemImage: "stop.circle")
                    }

                    if endRepeatType == .onDate {
                        DatePicker(L10n.tr("schedule.end_date"), selection: $endRepeatDate, displayedComponents: .date)
                    }

                    if endRepeatType == .afterCount {
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
                    }
                }
            }

            if let nextDate = previewNextRun() {
                Section {
                    LabeledContent {
                        Text(nextDate.formatted(date: .abbreviated, time: .standard))
                            .foregroundStyle(.secondary)
                    } label: {
                        Label(L10n.tr("task.detail.next_run"), systemImage: "clock.arrow.circlepath")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Script Tab

    private var scriptTab: some View {
        Form {
            Section {
                Picker(L10n.tr("editor.script.source"), selection: $scriptSource) {
                    ForEach(ScriptSource.allCases, id: \.self) { source in
                        Text(source.label).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                if scriptSource == .inline {
                    ScriptEditorView(scriptBody: $scriptBody)
                } else {
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

                    if !scriptFilePath.isEmpty,
                       let content = try? String(contentsOfFile: scriptFilePath, encoding: .utf8) {
                        Text(content.prefix(500) + (content.count > 500 ? "\n..." : ""))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(L10n.tr("editor.section.script")) {
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
        }
        .formStyle(.grouped)
    }

    // MARK: - Notification Tab

    private var notificationTab: some View {
        Form {
            Section {
                Toggle(L10n.tr("editor.notify_success"), isOn: $notifyOnSuccess)
                Toggle(L10n.tr("editor.notify_failure"), isOn: $notifyOnFailure)
            } header: {
                Text(L10n.tr("editor.section.notification"))
            } footer: {
                Text(L10n.tr("editor.notify_hint"))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private func closeWindow() {
        editorState.close()
        // Close the editor window by finding it
        for window in NSApp.windows where window.identifier?.rawValue == "editor" || window.title == L10n.tr("editor.title.edit") || window.title == L10n.tr("editor.title.new") {
            window.close()
            return
        }
        NSApp.keyWindow?.close()
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
        let currentId = task?.id
        guard currentId != loadedTaskId else { return }
        loadedTaskId = currentId

        // Reset to defaults for new task
        name = ""
        isEnabled = true
        scheduledDate = Date()
        hasDate = true
        hasTime = true
        repeatType = .daily
        endRepeatType = .never
        endRepeatDate = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
        endRepeatCount = 10
        customIntervalValue = 1
        customIntervalUnit = .day
        shell = "/bin/zsh"
        scriptBody = ""
        scriptSource = .inline
        scriptFilePath = ""
        workingDirectory = ""
        timeoutSeconds = 300
        notifyOnSuccess = false
        notifyOnFailure = true
        selectedTab = 0

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
        customIntervalValue = task.customIntervalValue
        customIntervalUnit = task.customIntervalUnit

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

        // Always set scheduledDate so the scheduler has a base time
        target.scheduledDate = scheduledDate
        target.repeatType = repeatType
        target.endRepeatType = repeatType == .never ? .never : endRepeatType
        target.endRepeatDate = endRepeatType == .onDate ? endRepeatDate : nil
        target.endRepeatCount = endRepeatType == .afterCount ? endRepeatCount : nil
        target.customIntervalValue = customIntervalValue
        target.customIntervalUnit = customIntervalUnit

        target.cronExpression = nil
        target.intervalSeconds = nil

        if scriptSource == .file {
            target.scriptFilePath = scriptFilePath
            target.scriptBody = ""
        } else {
            target.scriptFilePath = nil
            target.scriptBody = scriptBody
        }

        if isEnabled {
            target.nextRunAt = TaskScheduler.shared.computeNextRunDate(for: target)
        } else {
            target.nextRunAt = nil
        }

        if task == nil {
            modelContext.insert(target)
        }

        try? modelContext.save()
        TaskScheduler.shared.rebuildSchedule()
        closeWindow()
    }
}
