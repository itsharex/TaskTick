# TaskTick Raycast Extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a TaskTick Raycast extension. Adds an `ActionToast` helper + `events` CLI subcommand to the main TaskTick repo, then builds a new `tasktick-raycast` extension that talks to TaskTick exclusively through the existing CLI.

**Architecture:** Phase A modifies `~/Documents/Dev/myspace/TaskTick-app` (Swift). Phase B creates a brand-new repo at `~/Documents/Dev/myspace/tasktick-raycast` (TypeScript/React). The Raycast side discovers the CLI via `cliPath` preference (manual override) → fallback discovery; in dev the user points it at `tasktick-dev` from the parallel-installed `TaskTick Dev.app`.

**Tech Stack:** Swift 5.10 + ArgumentParser + SwiftData (TaskTick-app side). TypeScript + React + Raycast API + `@raycast/utils` (extension side). No bundler needed beyond Raycast's own toolchain.

**Reference spec:** `docs/superpowers/specs/2026-05-08-raycast-extension-implementation-spec.md`

---

## File Structure (new + modified)

### TaskTick-app (modified)

| Action | Path | Responsibility |
|---|---|---|
| **Create** | `Sources/Engine/ActionToast.swift` | Action-event banners (started/stopped/restarted/failed). Wraps NotificationManager. |
| **Create** | `Sources/CLI/Commands/EventsCommand.swift` | `tasktick events` long-running NDJSON streamer. |
| **Modify** | `Sources/CLI/TaskTickCLI.swift` | Register EventsCommand in subcommands list. |
| **Modify** | `Sources/Engine/CLIBridge.swift` | Hook ActionToast into handle() success + lookup-failed paths. |
| **Modify** | `Sources/Views/Main/TaskListView.swift` | Add ActionToast to play/stop button onTap. |
| **Modify** | `Sources/Views/Main/TaskDetailView.swift` | Add ActionToast to run/stop button onTap (3 sites). |
| **Modify** | `Sources/Views/MenuBar/MenuBarView.swift` | Add ActionToast to 4 execute/cancel sites. |
| **Modify** | `Sources/Views/QuickLauncher/QuickLauncherView.swift` | Add ActionToast to 4 execute/cancel sites. |
| **Modify** | `Sources/TaskTickCore/Localization/*/Localizable.strings` | Add `toast.action.{started,stopped,restarted,failed}` keys to all 11 locales. |
| **Create** | `Tests/AppTests/ActionToastTests.swift` | Unit tests for the helper. |
| **Create** | `Tests/CLITests/EventsCommandTests.swift` | Integration smoke tests for `tasktick events`. |

### tasktick-raycast (new repo)

| Path | Responsibility |
|---|---|
| `package.json` | Raycast manifest (1 view command, 3 preferences). |
| `tsconfig.json`, `eslint.config.mjs`, `.gitignore` | Standard Raycast scaffolding. |
| `assets/extension-icon.png`, `assets/command-icon.png` | 256x256 icons (placeholder until polish). |
| `src/search-tasks.tsx` | Top-level command entry — renders `<TasksList />`. |
| `src/lib/types.ts` | TS types mirroring §5.4 JSON schemas. |
| `src/lib/cli-detection.ts` | Resolve cliPath preference → fallback chain → null. |
| `src/lib/tasktick.ts` | execa wrapper for list/run/stop/restart/reveal/logs. |
| `src/lib/events.ts` | Long-running `tasktick events` subprocess + EventEmitter. |
| `src/lib/format.ts` | Status icons, time formatters, error message extractors. |
| `src/views/tasks-list.tsx` | List + ActionPanel main view. |
| `src/views/logs-detail.tsx` | View Last Output detail. |
| `src/views/cli-not-found.tsx` | Fallback when CLI is missing. |
| `tests/cli-detection.test.ts`, `tests/events.test.ts` | Vitest unit tests for pure logic. |
| `README.md`, `CHANGELOG.md` | Store-grade docs (English). |

---

# Phase A: TaskTick.app changes

Phase A produces a TaskTick build with action toasts + the new `events` CLI subcommand. Verify each task by running `./scripts/build-dev.sh` and exercising the new behavior.

---

## Task 1: ActionToast helper + l10n strings

**Files:**
- Create: `Sources/Engine/ActionToast.swift`
- Modify: `Sources/TaskTickCore/Localization/en.lproj/Localizable.strings`
- Modify: `Sources/TaskTickCore/Localization/zh-Hans.lproj/Localizable.strings`
- Modify: `Sources/TaskTickCore/Localization/{zh-Hant,ja,ko,fr,de,es,it,id,ru}.lproj/Localizable.strings`
- Test: `Tests/AppTests/ActionToastTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/AppTests/ActionToastTests.swift
import XCTest
@testable import TaskTickApp

final class ActionToastTests: XCTestCase {
    func testStartedTitleAndBody() {
        let (title, body) = ActionToast.previewContent(for: .started(taskName: "Backup"))
        XCTAssertEqual(title, "Started")           // English locale assumed in test env
        XCTAssertEqual(body, "Backup")
    }

    func testStoppedRestartedFailedBodies() {
        XCTAssertEqual(ActionToast.previewContent(for: .stopped(taskName: "X")).title, "Stopped")
        XCTAssertEqual(ActionToast.previewContent(for: .restarted(taskName: "X")).title, "Restarted")
        let failed = ActionToast.previewContent(for: .failed(taskName: "X", reason: "not found"))
        XCTAssertEqual(failed.title, "Action failed")
        XCTAssertTrue(failed.body.contains("X"))
        XCTAssertTrue(failed.body.contains("not found"))
    }

    func testFailedWithoutTaskNameUsesReasonOnly() {
        let (_, body) = ActionToast.previewContent(for: .failed(taskName: nil, reason: "unknown id"))
        XCTAssertEqual(body, "unknown id")
    }
}
```

- [ ] **Step 2: Run test — should fail (no ActionToast type yet)**

Run: `swift test --filter ActionToastTests`
Expected: compile error "cannot find ActionToast in scope".

- [ ] **Step 3: Implement ActionToast.swift**

```swift
// Sources/Engine/ActionToast.swift
import Foundation
import TaskTickCore

/// Single entry point for "user just performed an action" banners.
/// Run/Stop/Restart success → fires UN banner. Reveal does NOT fire.
/// Failures (CLIBridge couldn't resolve a task etc.) also fire.
enum ActionToast {

    enum Event {
        case started(taskName: String)
        case stopped(taskName: String)
        case restarted(taskName: String)
        case failed(taskName: String?, reason: String)
    }

    /// Globally toggle action banners. Reuses the existing
    /// `notificationsEnabled` UserDefaults key — when the user has turned
    /// off notifications globally, we honor that.
    static func notify(_ event: Event) {
        let enabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true
        guard enabled else { return }
        let (title, body) = previewContent(for: event)
        NotificationManager.shared.sendNotification(title: title, body: body)
    }

    /// Pure helper used by tests — renders the strings without sending.
    static func previewContent(for event: Event) -> (title: String, body: String) {
        switch event {
        case .started(let name):
            return (L10n.tr("toast.action.started"), name)
        case .stopped(let name):
            return (L10n.tr("toast.action.stopped"), name)
        case .restarted(let name):
            return (L10n.tr("toast.action.restarted"), name)
        case .failed(let name, let reason):
            let body = name.map { "\($0): \(reason)" } ?? reason
            return (L10n.tr("toast.action.failed"), body)
        }
    }
}
```

- [ ] **Step 4: Add localization keys to en + zh-Hans**

Append to `Sources/TaskTickCore/Localization/en.lproj/Localizable.strings`:
```
"toast.action.started" = "Started";
"toast.action.stopped" = "Stopped";
"toast.action.restarted" = "Restarted";
"toast.action.failed" = "Action failed";
```

Append to `Sources/TaskTickCore/Localization/zh-Hans.lproj/Localizable.strings`:
```
"toast.action.started" = "已启动";
"toast.action.stopped" = "已停止";
"toast.action.restarted" = "已重启";
"toast.action.failed" = "操作失败";
```

- [ ] **Step 5: Add the same 4 keys to the 9 other locales**

For each of `zh-Hant, ja, ko, fr, de, es, it, id, ru`, append the 4 keys with reasonable translations. If the agent isn't fluent, copy the English values verbatim — translation polish can land in a separate PR. **Don't skip any locale**: missing keys cause `L10n.tr` to return the key string ("toast.action.started") which is user-visible.

- [ ] **Step 6: Verify tests pass**

Run: `swift test --filter ActionToastTests`
Expected: all 3 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/Engine/ActionToast.swift \
        Sources/TaskTickCore/Localization/*/Localizable.strings \
        Tests/AppTests/ActionToastTests.swift
git commit -m "engine: ActionToast helper for user-action banners"
```

---

## Task 2: Hook ActionToast into CLIBridge

**Files:**
- Modify: `Sources/Engine/CLIBridge.swift:40-71` (handle method)
- Reuse: `Tests/AppTests/` — manual smoke test only (CLIBridge has no test fixture; the unit test for ActionToast already covers the helper).

- [ ] **Step 1: Replace CLIBridge.handle with toast-emitting version**

Replace the body of `handle(action:taskId:)` (lines 40–71) with this version, which adds `ActionToast.notify(...)` calls after each successful dispatch and on the lookup-failed path:

```swift
func handle(action: Action, taskId: UUID) {
    guard let container = modelContainer else {
        NSLog("⚠️ CLIBridge: handle(\(action.rawValue)) called before configure()")
        ActionToast.notify(.failed(taskName: nil, reason: "TaskTick not ready"))
        return
    }
    let context = container.mainContext
    let descriptor = FetchDescriptor<ScheduledTask>(predicate: #Predicate { $0.id == taskId })
    guard let task = try? context.fetch(descriptor).first else {
        NSLog("⚠️ CLIBridge: no task with id \(taskId)")
        ActionToast.notify(.failed(taskName: nil, reason: "task not found"))
        return
    }

    switch action {
    case .run:
        guard !TaskScheduler.shared.runningTaskIDs.contains(task.id) else { return }
        Task { _ = await ScriptExecutor.shared.execute(task: task, modelContext: context) }
        ActionToast.notify(.started(taskName: task.name))
    case .stop:
        ScriptExecutor.shared.cancel(taskId: task.id)
        ActionToast.notify(.stopped(taskName: task.name))
    case .restart:
        let wasRunning = TaskScheduler.shared.runningTaskIDs.contains(task.id)
        if wasRunning { ScriptExecutor.shared.cancel(taskId: task.id) }
        Task {
            if wasRunning { try? await Task.sleep(for: .milliseconds(200)) }
            _ = await ScriptExecutor.shared.execute(task: task, modelContext: context)
        }
        ActionToast.notify(.restarted(taskName: task.name))
    case .reveal:
        MainWindowSelection.shared.taskToReveal = task
        NotificationCenter.default.post(name: .revealTaskInMain, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        // No toast — reveal's feedback is the window opening.
    }
}
```

- [ ] **Step 2: Build dev**

Run: `./scripts/build-dev.sh`
Expected: build succeeds, dev app restarts.

- [ ] **Step 3: Manual smoke test**

In a terminal:
```bash
/Applications/TaskTick\ Dev.app/Contents/MacOS/tasktick-dev list --json | jq '.[0].id'
```
Copy the first task's ID, then:
```bash
/Applications/TaskTick\ Dev.app/Contents/MacOS/tasktick-dev run <that-id>
```
Expected: macOS notification banner shows "Started — \<task name\>".
Repeat for stop, restart. Verify `reveal` does NOT show a banner.

- [ ] **Step 4: Commit**

```bash
git add Sources/Engine/CLIBridge.swift
git commit -m "engine: emit ActionToast on CLI bridge writes"
```

---

## Task 3: Hook ActionToast into Main views (TaskListView + TaskDetailView)

**Files:**
- Modify: `Sources/Views/Main/TaskListView.swift:194,199` (cancel + execute call sites)
- Modify: `Sources/Views/Main/TaskDetailView.swift:175,184,616` (3 call sites)

- [ ] **Step 1: Read TaskListView.swift around the call sites**

Run: `Read tool, file Sources/Views/Main/TaskListView.swift, lines 180-210`
Note the surrounding code so the agent can identify which `task` variable is in scope.

- [ ] **Step 2: Add ActionToast call adjacent to each ScriptExecutor invocation**

Pattern to apply at each site:
- Right after `ScriptExecutor.shared.cancel(taskId: task.id)` → add `ActionToast.notify(.stopped(taskName: task.name))`
- Right after `_ = await ScriptExecutor.shared.execute(task: task, modelContext: ...)` → add `ActionToast.notify(.started(taskName: task.name))`

Edit each site with a small surrounding context to keep the Edit tool unambiguous.

For TaskListView line 194/199:
```swift
// Before:
                    ScriptExecutor.shared.cancel(taskId: task.id)
                } else {
                    Task {
                        _ = await ScriptExecutor.shared.execute(task: task, modelContext: modelContext)
                    }
                }

// After:
                    ScriptExecutor.shared.cancel(taskId: task.id)
                    ActionToast.notify(.stopped(taskName: task.name))
                } else {
                    Task {
                        _ = await ScriptExecutor.shared.execute(task: task, modelContext: modelContext)
                    }
                    ActionToast.notify(.started(taskName: task.name))
                }
```

(Place the `started` notify outside the Task closure so it fires immediately when the user clicks, not when the script eventually starts running.)

- [ ] **Step 3: Apply the same pattern to TaskDetailView.swift lines 175, 184, 616**

For lines 175/184 (the main run/stop button):
```swift
// Existing: ScriptExecutor.shared.cancel(taskId: task.id) ... await execute(...)
// Add: ActionToast.notify(.stopped(taskName: task.name)) / .started(taskName: task.name)
```

Line 616 is another cancel site (for the inline running-task strip). Add `.stopped` toast there too.

- [ ] **Step 4: Build dev + smoke test**

Run: `./scripts/build-dev.sh`
Open TaskTick Dev → click play on a task → verify "Started" banner. Click stop on a running task → verify "Stopped" banner.

- [ ] **Step 5: Commit**

```bash
git add Sources/Views/Main/TaskListView.swift Sources/Views/Main/TaskDetailView.swift
git commit -m "views: ActionToast on main-window run/stop buttons"
```

---

## Task 4: Hook ActionToast into MenuBar + QuickLauncher

**Files:**
- Modify: `Sources/Views/MenuBar/MenuBarView.swift:238,256,289,294`
- Modify: `Sources/Views/QuickLauncher/QuickLauncherView.swift:354,359,378,384`

- [ ] **Step 1: Apply same pattern as Task 3**

At each `ScriptExecutor.shared.cancel(taskId: task.id)` site → follow with `ActionToast.notify(.stopped(taskName: task.name))`.
At each `await ScriptExecutor.shared.execute(task:...)` site → follow with `ActionToast.notify(.started(taskName: task.name))` outside the Task closure.

There are 4 sites in MenuBarView and 4 in QuickLauncherView. Treat each as its own Edit. Read 5-10 lines of surrounding context first to disambiguate.

- [ ] **Step 2: Build dev + smoke test**

Run: `./scripts/build-dev.sh`
Open menu bar dropdown → click play on a task. Open Quick Launcher (default ⌃Space) → Enter a task. Both must show banners.

- [ ] **Step 3: Commit**

```bash
git add Sources/Views/MenuBar/MenuBarView.swift Sources/Views/QuickLauncher/QuickLauncherView.swift
git commit -m "views: ActionToast on menu bar + quick launcher actions"
```

---

## Task 5: Implement `tasktick events` subcommand

**Files:**
- Create: `Sources/CLI/Commands/EventsCommand.swift`
- Modify: `Sources/CLI/TaskTickCLI.swift` (register subcommand)
- Test: `Tests/CLITests/EventsCommandTests.swift`

- [ ] **Step 1: Write the failing integration test**

```swift
// Tests/CLITests/EventsCommandTests.swift
import XCTest
import Foundation
@testable import tasktick

final class EventsCommandTests: XCTestCase {

    /// Smoke test: post a synthetic taskStarted notification and verify the
    /// EventsCommand observer formats it as a single NDJSON line on stdout.
    func testStartedNotificationProducesNDJSONLine() throws {
        let id = UUID()
        let line = EventsCommand.formatStartedLine(id: id.uuidString,
                                                   executionId: "exec-1",
                                                   ts: "2026-05-08T10:00:00Z")
        // Must be valid JSON, single line, ends with newline.
        XCTAssertTrue(line.hasSuffix("\n"))
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "started")
        XCTAssertEqual(json?["id"] as? String, id.uuidString)
        XCTAssertEqual(json?["executionId"] as? String, "exec-1")
    }

    func testCompletedNotificationIncludesExitCode() throws {
        let line = EventsCommand.formatCompletedLine(id: "abc", executionId: "exec-2", exitCode: 7, ts: "2026-05-08T10:00:01Z")
        let json = try JSONSerialization.jsonObject(with: Data(line.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "completed")
        XCTAssertEqual(json?["exitCode"] as? Int, 7)
    }
}
```

- [ ] **Step 2: Run — should fail to compile (EventsCommand doesn't exist)**

Run: `swift test --filter EventsCommandTests`
Expected: "cannot find EventsCommand in scope".

- [ ] **Step 3: Implement EventsCommand**

```swift
// Sources/CLI/Commands/EventsCommand.swift
import ArgumentParser
import Foundation
import TaskTickCore

struct EventsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "Stream task lifecycle events as NDJSON. Long-running."
    )

    @MainActor
    func run() async throws {
        let bundleId = BundleContext.bundleID
        let startedName = Notification.Name("\(bundleId).gui.taskStarted")
        let completedName = Notification.Name("\(bundleId).gui.taskCompleted")
        let center = DistributedNotificationCenter.default()
        let stdout = FileHandle.standardOutput

        // Ctrl+C → exit 130 (Unix convention).
        signal(SIGINT, SIG_IGN)
        let intSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSrc.setEventHandler { Foundation.exit(130) }
        intSrc.resume()

        // SIGTERM → clean exit 0 (Raycast extension calling proc.kill).
        signal(SIGTERM, SIG_IGN)
        let termSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSrc.setEventHandler { Foundation.exit(0) }
        termSrc.resume()

        let isoFormatter = ISO8601DateFormatter()

        let onStarted: (Notification) -> Void = { note in
            guard let info = note.userInfo,
                  let id = info["id"] as? String else { return }
            let executionId = (info["executionId"] as? String) ?? ""
            let ts = (info["startedAt"] as? String) ?? isoFormatter.string(from: Date())
            let line = Self.formatStartedLine(id: id, executionId: executionId, ts: ts)
            try? stdout.write(contentsOf: Data(line.utf8))
        }
        let onCompleted: (Notification) -> Void = { note in
            guard let info = note.userInfo,
                  let id = info["id"] as? String else { return }
            let executionId = (info["executionId"] as? String) ?? ""
            let exitCode = (info["exitCode"] as? Int) ?? 0
            let ts = (info["endedAt"] as? String) ?? isoFormatter.string(from: Date())
            let line = Self.formatCompletedLine(id: id, executionId: executionId, exitCode: exitCode, ts: ts)
            try? stdout.write(contentsOf: Data(line.utf8))
        }

        center.addObserver(forName: startedName,   object: nil, queue: .main, using: onStarted)
        center.addObserver(forName: completedName, object: nil, queue: .main, using: onCompleted)

        // Park forever; signal handlers exit the process.
        RunLoop.main.run()
    }

    /// Pure formatter — testable without subscribing.
    static func formatStartedLine(id: String, executionId: String, ts: String) -> String {
        let payload: [String: Any] = ["type": "started", "id": id, "executionId": executionId, "ts": ts]
        return Self.encode(payload)
    }

    static func formatCompletedLine(id: String, executionId: String, exitCode: Int, ts: String) -> String {
        let payload: [String: Any] = ["type": "completed", "id": id, "executionId": executionId, "exitCode": exitCode, "ts": ts]
        return Self.encode(payload)
    }

    private static func encode(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "{}\n"
        }
        return s + "\n"
    }
}
```

- [ ] **Step 4: Register EventsCommand in TaskTickCLI**

```swift
// Sources/CLI/TaskTickCLI.swift — add to subcommands array
subcommands: [
    ListCommand.self,
    StatusCommand.self,
    LogsCommand.self,
    RunCommand.self,
    StopCommand.self,
    RestartCommand.self,
    RevealCommand.self,
    TailCommand.self,
    WaitCommand.self,
    EventsCommand.self,        // ← add this line
    CompletionCommand.self
]
```

- [ ] **Step 5: Run tests, expect green**

Run: `swift test --filter EventsCommandTests`
Expected: both tests pass.

- [ ] **Step 6: End-to-end smoke test**

Open two terminals.

Terminal 1: `./scripts/build-dev.sh` then run `/Applications/TaskTick\ Dev.app/Contents/MacOS/tasktick-dev events`. Should hang waiting for events.

Terminal 2: list a task, run it via CLI:
```bash
TT_BIN="/Applications/TaskTick Dev.app/Contents/MacOS/tasktick-dev"
"$TT_BIN" run "$("$TT_BIN" list --json | jq -r '.[0].id')"
```

Terminal 1 should print one `{"type":"started",...}` line, and a few seconds later a `{"type":"completed",...}` line. Ctrl+C terminal 1 — should exit immediately.

- [ ] **Step 7: Commit**

```bash
git add Sources/CLI/Commands/EventsCommand.swift Sources/CLI/TaskTickCLI.swift Tests/CLITests/EventsCommandTests.swift
git commit -m "cli: add events subcommand for NDJSON lifecycle stream"
```

---

# Phase B: tasktick-raycast extension

Phase B is a brand new repo. No existing context to read. Each task starts with a clean checkpoint.

**Pre-Phase-B verification:** Phase A's `events` subcommand must work end-to-end before starting Phase B (Task 9 depends on it).

---

## Task 6: Scaffold the tasktick-raycast repo

**Files:** all newly created.

- [ ] **Step 1: Create directory and initialize Raycast extension**

```bash
mkdir -p ~/Documents/Dev/myspace/tasktick-raycast
cd ~/Documents/Dev/myspace/tasktick-raycast
npx --yes create-raycast-extension --name tasktick --title TaskTick --description "Quick launcher for TaskTick scheduled tasks" --template view-command
```

If `create-raycast-extension` prompts interactively for any remaining fields, accept defaults (author = your GitHub handle, category = Productivity).

- [ ] **Step 2: Replace template files with our structure**

Delete the template-generated `src/index.tsx` (or whatever default file came in). We'll create our own files in subsequent tasks.

```bash
rm -f src/*.tsx src/*.ts
mkdir -p src/lib src/views tests
```

- [ ] **Step 3: Configure package.json**

Replace `package.json`'s `preferences` and `commands` arrays with this exact content (preserve other fields the scaffold added like `author`, `license`, `dependencies`):

```jsonc
"preferences": [
    {
        "name": "cliPath",
        "type": "textfield",
        "required": false,
        "title": "CLI Path",
        "description": "Path to the tasktick CLI. Auto-detected if empty. For dev, point to /Applications/TaskTick Dev.app/Contents/MacOS/tasktick-dev.",
        "placeholder": "/usr/local/bin/tasktick"
    },
    {
        "name": "showCompletionToast",
        "type": "checkbox",
        "required": false,
        "title": "Show in-Raycast Toast",
        "label": "Show feedback toast on Run/Stop/Restart",
        "default": true
    },
    {
        "name": "logsFormat",
        "type": "dropdown",
        "required": false,
        "title": "Logs Display",
        "default": "text",
        "data": [
            { "title": "Plain text", "value": "text" },
            { "title": "JSON", "value": "json" }
        ]
    }
],
"commands": [
    {
        "name": "search-tasks",
        "title": "Search Tasks",
        "description": "Search and run TaskTick tasks",
        "mode": "view"
    }
]
```

- [ ] **Step 4: Add vitest as the test runner**

```bash
npm install --save-dev vitest @types/node
```

Add to `package.json` scripts:
```jsonc
"scripts": {
    "build": "ray build",
    "dev": "ray develop",
    "lint": "ray lint",
    "test": "vitest run",
    "test:watch": "vitest"
}
```

Add a minimal `vitest.config.ts`:
```ts
import { defineConfig } from "vitest/config";
export default defineConfig({
    test: { environment: "node", include: ["tests/**/*.test.ts"] }
});
```

- [ ] **Step 5: Initialize git + first commit**

```bash
git init
echo "node_modules\n.raycast\n*.log\n.DS_Store\ndist\n" > .gitignore
git add .
git commit -m "chore: scaffold tasktick raycast extension"
```

- [ ] **Step 6: Push to GitHub**

```bash
gh repo create lifedever/tasktick-raycast --public --source . --push --description "Quick launcher for TaskTick scheduled tasks"
```

(If `gh` is not authenticated, fall back to manual remote setup.)

---

## Task 7: Types + CLI detection

**Files:**
- Create: `src/lib/types.ts`
- Create: `src/lib/cli-detection.ts`
- Test: `tests/cli-detection.test.ts`

- [ ] **Step 1: Define types mirroring §5.4 schemas**

```ts
// src/lib/types.ts
export type TaskKind = "scheduled" | "manual";
export type TaskStatus = "idle" | "running";

export interface Task {
    id: string;
    shortId: string;
    name: string;
    kind: TaskKind;
    enabled: boolean;
    status: TaskStatus;
    scheduleSummary: string;
    lastRunAt?: string;
    lastRunDurationSec?: number;
    lastExitCode?: number;
    createdAt: string;
}

export interface ExecutionLogLine {
    ts: string;
    stream: "stdout" | "stderr";
    text: string;
}

export interface ExecutionLog {
    executionId: string;
    taskId: string;
    startedAt: string;
    endedAt?: string;
    exitCode?: number;
    stdout: string;
    stderr: string;
    lines: ExecutionLogLine[];
}

export type LifecycleEvent =
    | { type: "started";   id: string; executionId: string; ts: string }
    | { type: "completed"; id: string; executionId: string; exitCode: number; ts: string };
```

- [ ] **Step 2: Write the failing test for cli-detection**

```ts
// tests/cli-detection.test.ts
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, chmodSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveCliPath } from "../src/lib/cli-detection";

let tmp: string;

beforeEach(() => { tmp = mkdtempSync(join(tmpdir(), "tasktick-")); });
afterEach(() => { rmSync(tmp, { recursive: true, force: true }); });

function makeExe(path: string) {
    writeFileSync(path, "#!/bin/sh\nexit 0");
    chmodSync(path, 0o755);
}

describe("resolveCliPath", () => {
    it("prefers preference path when executable exists", async () => {
        const p = join(tmp, "custom-tasktick");
        makeExe(p);
        const got = await resolveCliPath(p, []);
        expect(got).toBe(p);
    });

    it("falls back through candidate list", async () => {
        const p = join(tmp, "fallback-tasktick");
        makeExe(p);
        const got = await resolveCliPath(undefined, [join(tmp, "missing"), p]);
        expect(got).toBe(p);
    });

    it("returns null when nothing exists", async () => {
        const got = await resolveCliPath(undefined, [join(tmp, "nope")]);
        expect(got).toBeNull();
    });

    it("ignores non-executable files", async () => {
        const p = join(tmp, "not-exec");
        writeFileSync(p, "");
        const got = await resolveCliPath(p, []);
        expect(got).toBeNull();
    });
});
```

- [ ] **Step 3: Implement cli-detection**

```ts
// src/lib/cli-detection.ts
import { promises as fs, constants as fsConstants } from "node:fs";

const DEFAULT_FALLBACKS = [
    "/usr/local/bin/tasktick",
    "/opt/homebrew/bin/tasktick",
    "/Applications/TaskTick.app/Contents/MacOS/tasktick"
];

async function isExecutable(path: string): Promise<boolean> {
    try {
        await fs.access(path, fsConstants.X_OK);
        return true;
    } catch {
        return false;
    }
}

/**
 * Resolves the first existing + executable path.
 * @param preferred Optional user-supplied path from preferences.
 * @param fallbacks Override default fallback chain (mainly for tests).
 */
export async function resolveCliPath(
    preferred: string | undefined,
    fallbacks: string[] = DEFAULT_FALLBACKS
): Promise<string | null> {
    if (preferred && preferred.trim().length > 0) {
        return (await isExecutable(preferred)) ? preferred : null;
    }
    for (const candidate of fallbacks) {
        if (await isExecutable(candidate)) return candidate;
    }
    return null;
}

export const CLI_FALLBACK_PATHS = DEFAULT_FALLBACKS;
```

- [ ] **Step 4: Run tests, expect pass**

Run: `npm test`
Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/lib/types.ts src/lib/cli-detection.ts tests/cli-detection.test.ts
git commit -m "lib: types schema mirror + cli path resolver"
```

---

## Task 8: tasktick.ts shell-out wrapper

**Files:**
- Create: `src/lib/tasktick.ts`

(No test file — execa wrappers are integration-tested via the actual CLI in Task 10. Unit testing the shell out adds little value over manual `npm run dev` testing.)

- [ ] **Step 1: Implement the wrapper**

```ts
// src/lib/tasktick.ts
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { ExecutionLog, Task } from "./types";

const execFileAsync = promisify(execFile);

export class CliError extends Error {
    constructor(public readonly stderr: string, public readonly exitCode: number) {
        super(stderr.split("\n")[0] || `tasktick exited with code ${exitCode}`);
    }
}

async function runJSON<T>(cliPath: string, args: string[]): Promise<T> {
    try {
        const { stdout } = await execFileAsync(cliPath, [...args, "--json"], { maxBuffer: 16 * 1024 * 1024 });
        return JSON.parse(stdout) as T;
    } catch (err: any) {
        if (typeof err?.code === "number" || typeof err?.code === "string") {
            throw new CliError(err.stderr ?? String(err), Number(err.code) || 1);
        }
        throw err;
    }
}

async function runVoid(cliPath: string, args: string[]): Promise<void> {
    try {
        await execFileAsync(cliPath, args);
    } catch (err: any) {
        throw new CliError(err.stderr ?? String(err), Number(err.code) || 1);
    }
}

export const tasktick = {
    list: (cliPath: string) => runJSON<Task[]>(cliPath, ["list"]),
    status: (cliPath: string, id?: string) => runJSON<unknown>(cliPath, id ? ["status", id] : ["status"]),
    logs:  (cliPath: string, id: string) => runJSON<ExecutionLog>(cliPath, ["logs", id]),
    run:     (cliPath: string, id: string) => runVoid(cliPath, ["run", id]),
    stop:    (cliPath: string, id: string) => runVoid(cliPath, ["stop", id]),
    restart: (cliPath: string, id: string) => runVoid(cliPath, ["restart", id]),
    reveal:  (cliPath: string, id: string) => runVoid(cliPath, ["reveal", id])
};
```

- [ ] **Step 2: Type-check**

Run: `npx tsc --noEmit`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add src/lib/tasktick.ts
git commit -m "lib: tasktick CLI shell-out wrapper"
```

---

## Task 9: events.ts subprocess manager

**Files:**
- Create: `src/lib/events.ts`
- Test: `tests/events.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// tests/events.test.ts
import { describe, it, expect } from "vitest";
import { EventsStream } from "../src/lib/events";
import { mkdtempSync, writeFileSync, chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

function makeFakeCli(body: string): string {
    const dir = mkdtempSync(join(tmpdir(), "tt-cli-"));
    const path = join(dir, "tasktick");
    writeFileSync(path, `#!/bin/sh\n${body}`);
    chmodSync(path, 0o755);
    return path;
}

describe("EventsStream", () => {
    it("emits parsed events from NDJSON stdout", async () => {
        const cli = makeFakeCli(
            'echo \'{"type":"started","id":"abc","executionId":"e1","ts":"t"}\'\n' +
            'echo \'{"type":"completed","id":"abc","executionId":"e1","exitCode":0,"ts":"t"}\'\n' +
            'sleep 5'
        );
        const stream = new EventsStream(cli);
        const events: any[] = [];
        stream.on("started", (ev) => events.push({ type: "started", ...ev }));
        stream.on("completed", (ev) => events.push({ type: "completed", ...ev }));
        await new Promise((r) => setTimeout(r, 200));
        stream.kill();
        expect(events).toHaveLength(2);
        expect(events[0].type).toBe("started");
        expect(events[1].exitCode).toBe(0);
    });

    it("does not respawn after explicit kill", async () => {
        const cli = makeFakeCli("sleep 5");
        const stream = new EventsStream(cli);
        await new Promise((r) => setTimeout(r, 50));
        stream.kill();
        await new Promise((r) => setTimeout(r, 200));
        expect(stream.isAlive()).toBe(false);
    });

    it("retries with backoff after unexpected exit", async () => {
        const dir = mkdtempSync(join(tmpdir(), "tt-retry-"));
        const counterFile = join(dir, "counter");
        writeFileSync(counterFile, "0");
        const cliPath = join(dir, "tasktick");
        writeFileSync(cliPath, `#!/bin/sh\nn=$(cat "${counterFile}")\necho $((n+1)) > "${counterFile}"\nexit 1`);
        chmodSync(cliPath, 0o755);

        const stream = new EventsStream(cliPath, { initialBackoffMs: 20, maxBackoffMs: 100 });
        await new Promise((r) => setTimeout(r, 250));
        stream.kill();

        const { readFileSync } = await import("node:fs");
        const finalCount = parseInt(readFileSync(counterFile, "utf8"));
        expect(finalCount).toBeGreaterThan(1); // at least one retry happened
    });
});
```

- [ ] **Step 2: Run — should fail (no EventsStream)**

Run: `npm test`
Expected: import error.

- [ ] **Step 3: Implement EventsStream**

```ts
// src/lib/events.ts
import { spawn, ChildProcess } from "node:child_process";
import { EventEmitter } from "node:events";
import readline from "node:readline";
import type { LifecycleEvent } from "./types";

export interface EventsStreamOptions {
    initialBackoffMs?: number;
    maxBackoffMs?: number;
}

export interface EventsStreamEvents {
    started: (ev: { id: string; executionId: string; ts: string }) => void;
    completed: (ev: { id: string; executionId: string; exitCode: number; ts: string }) => void;
    error: (err: Error) => void;
}

export class EventsStream extends EventEmitter {
    private proc: ChildProcess | null = null;
    private retryTimer: NodeJS.Timeout | null = null;
    private retries = 0;
    private killed = false;
    private readonly initialBackoff: number;
    private readonly maxBackoff: number;

    constructor(private cliPath: string, opts: EventsStreamOptions = {}) {
        super();
        this.initialBackoff = opts.initialBackoffMs ?? 1000;
        this.maxBackoff = opts.maxBackoffMs ?? 60_000;
        this.start();
    }

    private start() {
        if (this.killed) return;
        this.proc = spawn(this.cliPath, ["events"], { stdio: ["ignore", "pipe", "pipe"] });
        const rl = readline.createInterface({ input: this.proc.stdout! });

        rl.on("line", (line) => {
            try {
                const ev = JSON.parse(line) as LifecycleEvent;
                this.emit(ev.type, ev);
                this.retries = 0; // healthy line → reset backoff
            } catch {
                // Ignore parse errors — bad line, keep going.
            }
        });

        this.proc.on("exit", () => {
            this.proc = null;
            if (this.killed) return;
            const backoff = Math.min(this.maxBackoff, this.initialBackoff * Math.pow(2, this.retries));
            this.retries += 1;
            this.retryTimer = setTimeout(() => {
                this.retryTimer = null;
                this.start();
            }, backoff);
        });

        this.proc.on("error", (err) => this.emit("error", err));
    }

    kill() {
        this.killed = true;
        if (this.retryTimer) {
            clearTimeout(this.retryTimer);
            this.retryTimer = null;
        }
        if (this.proc) {
            this.proc.kill("SIGTERM");
            this.proc = null;
        }
    }

    isAlive(): boolean {
        return this.proc !== null;
    }
}
```

- [ ] **Step 4: Run tests, expect green**

Run: `npm test`
Expected: all 3 tests pass. The retry test is timing-sensitive — if it flakes, increase the wait window from 250ms to 500ms.

- [ ] **Step 5: Commit**

```bash
git add src/lib/events.ts tests/events.test.ts
git commit -m "lib: events subprocess manager with reconnect"
```

---

## Task 10: Main view (search-tasks.tsx + tasks-list.tsx)

**Files:**
- Create: `src/search-tasks.tsx`
- Create: `src/views/tasks-list.tsx`
- Create: `src/lib/format.ts` (small helpers)

- [ ] **Step 1: Implement format helpers**

```ts
// src/lib/format.ts
import { Icon, Color } from "@raycast/api";
import type { Task } from "./types";

export function statusIcon(task: Task): { source: Icon; tintColor?: Color } {
    if (task.status === "running") return { source: Icon.Circle, tintColor: Color.Green };
    if (task.kind === "scheduled") return { source: Icon.Clock, tintColor: Color.Blue };
    return { source: Icon.Bolt, tintColor: Color.SecondaryText };
}

export function relativeTime(iso?: string): string {
    if (!iso) return "Never";
    const t = Date.parse(iso);
    if (Number.isNaN(t)) return "Never";
    const diffSec = Math.max(0, (Date.now() - t) / 1000);
    if (diffSec < 60) return `${Math.floor(diffSec)}s ago`;
    if (diffSec < 3600) return `${Math.floor(diffSec / 60)}m ago`;
    if (diffSec < 86400) return `${Math.floor(diffSec / 3600)}h ago`;
    return `${Math.floor(diffSec / 86400)}d ago`;
}
```

- [ ] **Step 2: Implement search-tasks.tsx (entry point)**

```tsx
// src/search-tasks.tsx
import { Detail, getPreferenceValues } from "@raycast/api";
import { useEffect, useState } from "react";
import { resolveCliPath } from "./lib/cli-detection";
import { TasksList } from "./views/tasks-list";
import { CliNotFound } from "./views/cli-not-found";

interface Prefs {
    cliPath?: string;
    showCompletionToast: boolean;
    logsFormat: "text" | "json";
}

export default function Command() {
    const prefs = getPreferenceValues<Prefs>();
    const [cliPath, setCliPath] = useState<string | null | undefined>(undefined);

    useEffect(() => { resolveCliPath(prefs.cliPath).then(setCliPath); }, [prefs.cliPath]);

    if (cliPath === undefined) return <Detail isLoading markdown="" />;
    if (cliPath === null) return <CliNotFound />;
    return <TasksList cliPath={cliPath} prefs={prefs} />;
}
```

- [ ] **Step 3: Implement tasks-list.tsx**

```tsx
// src/views/tasks-list.tsx
import { ActionPanel, Action, List, Icon, showToast, Toast, Clipboard, Keyboard } from "@raycast/api";
import { useEffect, useState, useCallback } from "react";
import { tasktick, CliError } from "../lib/tasktick";
import { EventsStream } from "../lib/events";
import { statusIcon, relativeTime } from "../lib/format";
import type { Task } from "../lib/types";
import { LogsDetail } from "./logs-detail";

interface Props {
    cliPath: string;
    prefs: { showCompletionToast: boolean; logsFormat: "text" | "json" };
}

export function TasksList({ cliPath, prefs }: Props) {
    const [tasks, setTasks] = useState<Task[]>([]);
    const [isLoading, setLoading] = useState(true);

    const refresh = useCallback(async () => {
        setLoading(true);
        try {
            const list = await tasktick.list(cliPath);
            setTasks(list);
        } catch (err) {
            const msg = err instanceof CliError ? err.message : String(err);
            await showToast({ style: Toast.Style.Failure, title: "Failed to load tasks", message: msg });
        } finally {
            setLoading(false);
        }
    }, [cliPath]);

    useEffect(() => { refresh(); }, [refresh]);

    // Subscribe to lifecycle events to keep running state fresh without polling.
    useEffect(() => {
        const stream = new EventsStream(cliPath);
        const setRunning = (id: string, running: boolean) =>
            setTasks((prev) => prev.map((t) => (t.id === id ? { ...t, status: running ? "running" : "idle" } : t)));
        stream.on("started",   ({ id }) => setRunning(id, true));
        stream.on("completed", ({ id }) => setRunning(id, false));
        return () => stream.kill();
    }, [cliPath]);

    const performAction = useCallback(async (verb: "run" | "stop" | "restart" | "reveal", task: Task) => {
        if (prefs.showCompletionToast) {
            await showToast({ style: Toast.Style.Animated, title: `${verb.charAt(0).toUpperCase() + verb.slice(1)}…`, message: task.name });
        }
        try {
            await tasktick[verb](cliPath, task.id);
            if (prefs.showCompletionToast) {
                await showToast({ style: Toast.Style.Success, title: `${verb.charAt(0).toUpperCase() + verb.slice(1)} complete`, message: task.name });
            }
            // Bounded fallback: if event stream doesn't update within 2s, force-refresh.
            setTimeout(() => refresh(), 2000);
        } catch (err) {
            const msg = err instanceof CliError ? err.message : String(err);
            await showToast({ style: Toast.Style.Failure, title: `${verb} failed`, message: msg });
        }
    }, [cliPath, prefs.showCompletionToast, refresh]);

    return (
        <List isLoading={isLoading} searchBarPlaceholder="Search tasks…">
            {tasks.map((task) => {
                const isRunning = task.status === "running";
                return (
                    <List.Item
                        key={task.id}
                        icon={statusIcon(task)}
                        title={task.name}
                        subtitle={task.scheduleSummary}
                        accessories={[
                            { text: relativeTime(task.lastRunAt), tooltip: "Last run" },
                            isRunning ? { icon: { source: Icon.CircleProgress, tintColor: "#22c55e" }, tooltip: "Running" } : { text: "" }
                        ]}
                        actions={
                            <ActionPanel>
                                {isRunning ? (
                                    <>
                                        <Action title="Stop"    icon={Icon.Stop} onAction={() => performAction("stop", task)} />
                                        <Action title="Restart" icon={Icon.RotateClockwise} shortcut={{ modifiers: ["cmd"], key: "r" }} onAction={() => performAction("restart", task)} />
                                    </>
                                ) : (
                                    <>
                                        <Action title="Run"  icon={Icon.Play} onAction={() => performAction("run", task)} />
                                        <Action title="Stop" icon={Icon.Stop} onAction={() => performAction("stop", task)} />
                                    </>
                                )}
                                <Action title="Reveal in TaskTick" icon={Icon.Window}
                                    shortcut={{ modifiers: ["cmd"], key: "o" }}
                                    onAction={() => performAction("reveal", task)} />
                                <Action.Push title="View Last Output" icon={Icon.Terminal}
                                    shortcut={{ modifiers: ["cmd"], key: "l" }}
                                    target={<LogsDetail cliPath={cliPath} taskId={task.id} taskName={task.name} format={prefs.logsFormat} />} />
                                <Action title="Copy Task ID" icon={Icon.Clipboard}
                                    shortcut={{ modifiers: ["cmd"], key: "c" }}
                                    onAction={() => Clipboard.copy(task.id)} />
                                <Action title="Refresh List" icon={Icon.ArrowClockwise}
                                    shortcut={{ modifiers: ["cmd", "shift"], key: "r" }}
                                    onAction={() => refresh()} />
                            </ActionPanel>
                        }
                    />
                );
            })}
        </List>
    );
}
```

- [ ] **Step 4: Type-check**

Run: `npx tsc --noEmit`
Expected: no errors. (If `LogsDetail` or `CliNotFound` aren't yet implemented, type errors will surface — Tasks 11 and 12 fix them.)

- [ ] **Step 5: Commit (skipping dev test until LogsDetail + CliNotFound exist)**

```bash
git add src/search-tasks.tsx src/views/tasks-list.tsx src/lib/format.ts
git commit -m "view: tasks list with action panel + event-driven state"
```

---

## Task 11: Logs detail view

**Files:**
- Create: `src/views/logs-detail.tsx`

- [ ] **Step 1: Implement LogsDetail**

```tsx
// src/views/logs-detail.tsx
import { Detail, ActionPanel, Action, Icon } from "@raycast/api";
import { useEffect, useState } from "react";
import { tasktick, CliError } from "../lib/tasktick";
import type { ExecutionLog } from "../lib/types";

interface Props {
    cliPath: string;
    taskId: string;
    taskName: string;
    format: "text" | "json";
}

export function LogsDetail({ cliPath, taskId, taskName, format }: Props) {
    const [log, setLog] = useState<ExecutionLog | null>(null);
    const [error, setError] = useState<string | null>(null);

    useEffect(() => {
        tasktick.logs(cliPath, taskId)
            .then(setLog)
            .catch((err) => setError(err instanceof CliError ? err.message : String(err)));
    }, [cliPath, taskId]);

    let markdown: string;
    if (error) {
        markdown = `# ${taskName}\n\n\`\`\`\n${error}\n\`\`\``;
    } else if (!log) {
        markdown = `# ${taskName}\n\nLoading…`;
    } else if (format === "json") {
        markdown = `# ${taskName}\n\n\`\`\`json\n${JSON.stringify(log, null, 2)}\n\`\`\``;
    } else {
        const exit = log.exitCode ?? "?";
        const lines = log.lines
            .map((l) => `[${l.ts.slice(11, 19)}] ${l.stream === "stderr" ? "⚠ " : "  "}${l.text}`)
            .join("\n");
        markdown = `# ${taskName}\n\nExit ${exit}\n\n\`\`\`\n${lines || "(no output)"}\n\`\`\``;
    }

    return (
        <Detail
            isLoading={!log && !error}
            markdown={markdown}
            actions={
                <ActionPanel>
                    {log && <Action.CopyToClipboard title="Copy Output" content={log.lines.map((l) => l.text).join("\n")} />}
                    <Action.OpenInBrowser title="Reveal Task in TaskTick"
                        url={`tasktick://reveal?id=${taskId}`} icon={Icon.Window} />
                </ActionPanel>
            }
        />
    );
}
```

- [ ] **Step 2: Type-check + commit**

```bash
npx tsc --noEmit
git add src/views/logs-detail.tsx
git commit -m "view: logs detail with text + json format"
```

---

## Task 12: CLI-not-found view

**Files:**
- Create: `src/views/cli-not-found.tsx`

- [ ] **Step 1: Implement the view**

```tsx
// src/views/cli-not-found.tsx
import { Detail, ActionPanel, Action, Icon, openCommandPreferences } from "@raycast/api";
import { CLI_FALLBACK_PATHS } from "../lib/cli-detection";

export function CliNotFound() {
    const markdown = `
# tasktick CLI not found

To use this extension, enable the TaskTick CLI:

1. Open **TaskTick → Settings → Command Line**
2. Click **Enable CLI…** and follow the prompt
3. Verify by running \`tasktick --version\` in your terminal

If you've installed the CLI at a non-standard location, set **CLI Path** in this extension's preferences.

### Auto-detection searches:

${CLI_FALLBACK_PATHS.map((p) => `- \`${p}\``).join("\n")}

### Don't have TaskTick yet?

Download it from [task-tick.lifedever.com](https://task-tick.lifedever.com).
`;

    return (
        <Detail
            markdown={markdown}
            actions={
                <ActionPanel>
                    <Action title="Open Extension Preferences" icon={Icon.Gear} onAction={openCommandPreferences} />
                    <Action.Open title="Open TaskTick" target="/Applications/TaskTick.app" icon={Icon.Window} />
                    <Action.OpenInBrowser title="Download TaskTick" url="https://task-tick.lifedever.com" />
                </ActionPanel>
            }
        />
    );
}
```

- [ ] **Step 2: Type-check + commit**

```bash
npx tsc --noEmit
git add src/views/cli-not-found.tsx
git commit -m "view: CLI-not-found onboarding detail"
```

---

## Task 13: End-to-end dev validation

**Files:** none (manual testing).

- [ ] **Step 1: Set Raycast cliPath preference to dev binary**

Open Raycast → search "TaskTick" → click the gear / "Configure Extension" → set CLI Path to:
```
/Applications/TaskTick Dev.app/Contents/MacOS/tasktick-dev
```

- [ ] **Step 2: Start the dev loop**

```bash
cd ~/Documents/Dev/myspace/tasktick-raycast
npm run dev
```

Raycast will auto-import. Search "Search Tasks" — your task list should appear.

- [ ] **Step 3: Exercise every action**

- Run a task → verify Raycast Toast + system banner from ActionToast (TaskTick Dev sends both)
- Stop running task → same dual toast
- Restart, Reveal, View Last Output, Copy Task ID, Refresh List
- Quit TaskTick Dev (`⌘Q`) → run a task in Raycast → verify the URL Scheme path wakes the GUI
- Set CLI Path to a bogus value → verify CliNotFound view appears

- [ ] **Step 4: Run lint**

```bash
npm run lint
```
Fix any errors flagged by Raycast's preset.

- [ ] **Step 5: Commit any fixes from the validation pass**

```bash
git add -A
git commit -m "polish: lint + dev pass fixes"
```

---

## Task 14: README + assets + Store readiness

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Replace: `assets/extension-icon.png`, `assets/command-icon.png`
- Create: `metadata/tasktick-1.png` … `tasktick-4.png` (screenshots)

- [ ] **Step 1: Write README.md (English-only)**

Cover: install (via gh + ray develop for now, Raycast Store later), usage (every action's shortcut), preferences (cliPath + dev tip), troubleshooting (CLI not found → enable in TaskTick).

- [ ] **Step 2: Drop in icons**

Use the TaskTick app icon (or a derivative) at 256x256 PNG. Reuse for both `extension-icon.png` and `command-icon.png` in v1. The app-icon-generator skill (mentioned in available skills) can help generate variants.

- [ ] **Step 3: Capture 4 screenshots at 1280x800**

Run `npm run dev` in fullscreen Raycast, screenshot:
1. Tasks list with 5+ tasks
2. ActionPanel open
3. View Last Output
4. CliNotFound state (set bad cliPath temporarily)

- [ ] **Step 4: Commit**

```bash
git add README.md CHANGELOG.md assets/ metadata/
git commit -m "docs: README + Store assets"
git push
```

---

## Task 15: Wait for TaskTick 1.5.x release, then submit Raycast Store PR

**Pre-requisite:** TaskTick 1.5.x release is shipped (cask updated, CLI in `/usr/local/bin/tasktick` for normal users).

This task is **not** part of subagent-driven execution — it requires human judgement (release timing, Raycast Store reviewer interaction). Treat as a follow-up checklist for the human:

- [ ] Cut TaskTick 1.5.x with the new ActionToast + events code
- [ ] Verify cask update Symlinks `/opt/homebrew/bin/tasktick` (Apple Silicon) and `/usr/local/bin/tasktick` (Intel)
- [ ] Update tasktick-raycast README to remove "dev install only" caveat
- [ ] Fork raycast/extensions, copy this extension into `extensions/tasktick/`
- [ ] Open PR per their CONTRIBUTING.md, expect 1-2 week review cycle

---

## Spec Coverage Check

| Spec section | Plan task |
|---|---|
| §2.1 ActionToast helper | Task 1 |
| §2.2 ActionToast hook into CLIBridge | Task 2 |
| §2.2 Hook GUI buttons (Main / MenuBar / QuickLauncher) | Tasks 3, 4 |
| §2.4 Events subcommand | Task 5 |
| §2.5 Localization strings | Task 1 |
| §3.1 Repo scaffold | Task 6 |
| §3.2 File structure | Tasks 6 (skeleton), 7-12 (each file) |
| §3.3 package.json (preferences + commands) | Task 6 |
| §3.4 Main view + ActionPanel | Task 10 |
| §3.5 events.ts subprocess manager | Task 9 |
| §3.6 cli-detection | Task 7 |
| §3.7 logs-detail | Task 11 |
| §3.8 Error handling (CliNotFound + Toast on errors) | Tasks 12 (view), 10 (toast) |
| §4 Dev workflow | Task 13 |
| §5.1 Local dev → §5.2 Store | Tasks 13, 14, 15 |
| §6 Tests | Tasks 1, 5, 7, 9 |
| §9 Implementation order | Tasks 1-14 follow §9 order |
