import SwiftUI
import SwiftData

struct MainWindowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @StateObject private var editorState = EditorState.shared
    @StateObject private var mainSelection = MainWindowSelection.shared
    @State private var selectedTask: ScheduledTask?
    @AppStorage("sortNewestFirst") private var sortNewestFirst = true
    @Binding var showingCrontabImport: Bool

    var body: some View {
        NavigationSplitView {
            TaskListView(selectedTask: $selectedTask, sortNewestFirst: $sortNewestFirst)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 350)
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Menu {
                            Button {
                                sortNewestFirst = true
                            } label: {
                                if sortNewestFirst {
                                    Label(L10n.tr("task.sort.newest_first"), systemImage: "checkmark")
                                } else {
                                    Text(L10n.tr("task.sort.newest_first"))
                                }
                            }
                            Button {
                                sortNewestFirst = false
                            } label: {
                                if !sortNewestFirst {
                                    Label(L10n.tr("task.sort.oldest_first"), systemImage: "checkmark")
                                } else {
                                    Text(L10n.tr("task.sort.oldest_first"))
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .help(sortNewestFirst ? L10n.tr("task.sort.newest_first") : L10n.tr("task.sort.oldest_first"))
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            EditorState.shared.openNew()
                            openWindow(id: "editor")
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help(L10n.tr("command.new_task"))
                    }
                }
        } detail: {
            if let task = selectedTask {
                TaskDetailView(task: task)
                    .id(task.id)
            } else {
                ContentUnavailableView {
                    Label(L10n.tr("task.select.title"), systemImage: "checklist")
                } description: {
                    Text(L10n.tr("task.select.description"))
                }
            }
        }
        .sheet(isPresented: $showingCrontabImport) {
            CrontabImportView()
        }
        .onChange(of: editorState.lastSavedTask) { _, newTask in
            if let task = newTask {
                selectedTask = task
                editorState.lastSavedTask = nil
            }
        }
        .onAppear {
            // When Quick Launcher opens the main window via ⌘O, the window
            // scene may instantiate fresh — pick up the rendezvous selection
            // here so the first render already shows the requested task.
            if let task = mainSelection.taskToReveal {
                selectedTask = task
                mainSelection.taskToReveal = nil
            }
        }
        .onChange(of: mainSelection.taskToReveal) { _, newTask in
            if let task = newTask {
                selectedTask = task
                mainSelection.taskToReveal = nil
            }
        }
    }
}
