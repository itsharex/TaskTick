# tasktick CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `tasktick` CLI binary to the TaskTick `.app`, plus the GUI-side bridge (URL Scheme + Distributed Notification handler + Settings "Enable CLI" UI) it needs to dispatch run/stop/restart/reveal commands. CLI v1 ships 9 commands: `list`, `status`, `logs`, `run`, `stop`, `restart`, `reveal`, `tail`, `wait` — covering Quick Launcher parity plus task-chain scripting and tab completion.

**Architecture:** CLI is a second `executableTarget` in the same `Package.swift`, sharing `Models/` + select `Engine/` files via `sources:` whitelist (no library extraction). Read commands open a read-only `ModelContainer` directly. Write commands post a `DistributedNotificationCenter` notification (or fall back to `tasktick://run?id=<uuid>` URL Scheme to wake the GUI). Stream commands subscribe to GUI-broadcast notifications. Spec: `docs/superpowers/specs/2026-05-08-raycast-extension-design.md`.

**Tech Stack:** Swift 6, SwiftPM, swift-argument-parser 1.5+, SwiftData, AppKit (URL Scheme handler in AppDelegate), DistributedNotificationCenter for IPC.

---

## File Map

**New files (TaskTick app side):**
- `Sources/Engine/CLIBridge.swift` — Single entry point; routes URL Scheme + Distributed Notification → ScriptExecutor / Scheduler / MainWindowSelection
- `Sources/Engine/CLIBroadcaster.swift` — Listens to ScriptExecutor events, broadcasts as Distributed Notifications for `tail` / `wait`
- `Sources/Views/Settings/CLIInstallSection.swift` — Settings UI for enabling the CLI symlink

**New files (CLI side):**
- `Sources/CLI/main.swift` — `@main` AsyncParsableCommand root
- `Sources/CLI/Commands/{List,Status,Logs,Run,Stop,Restart,Reveal,Tail,Wait,Completion}Command.swift`
- `Sources/CLI/Bridge/ReadOnlyStore.swift` — Read-only ModelContainer wrapper
- `Sources/CLI/Bridge/GUILauncher.swift` — Detect / launch / wait for GUI process
- `Sources/CLI/Bridge/NotificationBridge.swift` — DistributedNotification post + observe helpers
- `Sources/CLI/Output/TableRenderer.swift` — Human-readable table output
- `Sources/CLI/Output/TaskDTO.swift` — `Task` / `Status` / `ExecutionLogDTO` Codable types matching spec §5.4
- `Sources/CLI/Identifier/TaskResolver.swift` — UUID/prefix/name/fuzzy multi-tier resolution

**Modified files:**
- `Package.swift` — Add swift-argument-parser dep, add `tasktick` executable target
- `Sources/App/AppDelegate.swift` — Register URL Scheme handler, start CLIBridge + CLIBroadcaster
- `Sources/App/TaskTickApp.swift` — Wire CLIBridge into model container at boot
- `scripts/build-dev.sh` — Inject URL Scheme into Info.plist; copy CLI binary into `.app/Contents/MacOS/tasktick`
- `scripts/release.sh` — Same as build-dev.sh, both arches
- `Sources/Localization/{en,zh-Hans}.lproj/Localizable.strings` — New strings for Settings CLI section

**Tests:**
- `Tests/CLITests/TaskResolverTests.swift` — Identifier resolution cases
- `Tests/CLITests/TaskDTOTests.swift` — JSON encoding/decoding
- `Tests/CLITests/ReadOnlyStoreTests.swift` — Read-only enforcement
- `Tests/AppTests/CLIBridgeTests.swift` — URL parsing + action dispatch routing

---

## Phase 0: Package.swift + skeleton CLI target

### Task 0.1: Add swift-argument-parser dependency and CLI target

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CLI/main.swift`

- [ ] **Step 1: Update Package.swift**

Replace the entire file with:

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TaskTick",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "TaskTick",
            path: "Sources",
            exclude: ["CLI"],
            resources: [
                .process("Localization")
            ]
        ),
        .executableTarget(
            name: "tasktick",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources",
            exclude: [
                "App",
                "Views",
                "Localization",
                "Resources"
            ],
            sources: [
                "CLI",
                "Models/ScheduledTask.swift",
                "Models/ExecutionLog.swift",
                "Models/CronExpression.swift",
                "Engine/FuzzyMatch.swift",
                "Engine/StoreMigration.swift",
                "Engine/StoreHardener.swift"
            ]
        ),
        .testTarget(
            name: "TaskTickTests",
            dependencies: ["TaskTick"],
            path: "Tests/AppTests"
        ),
        .testTarget(
            name: "CLITests",
            dependencies: ["tasktick"],
            path: "Tests/CLITests"
        )
    ]
)
```

Notes:
- `TaskTick` target excludes `CLI/` so it doesn't accidentally pull main.swift into the GUI binary
- `tasktick` target excludes `App/Views/Localization/Resources` (none of which the CLI needs) and uses `sources:` whitelist to share specific files. Critically, it does NOT pull `Engine/TaskScheduler.swift` / `ScriptExecutor.swift` (those are `@MainActor` and link SwiftUI)
- Test targets split into `AppTests/` (existing `Tests/`) and `CLITests/` (new)

- [ ] **Step 2: Move existing Tests/ to Tests/AppTests/**

```bash
git mv Tests Tests-tmp
mkdir Tests
git mv Tests-tmp Tests/AppTests
mkdir Tests/CLITests
touch Tests/CLITests/.gitkeep
```

- [ ] **Step 3: Create skeleton CLI main.swift**

Create `Sources/CLI/main.swift`:

```swift
import ArgumentParser
import Foundation

@main
struct TaskTick: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tasktick",
        abstract: "Control TaskTick scheduled tasks from the command line.",
        version: "0.1.0",
        subcommands: [],
        defaultSubcommand: nil
    )
}
```

Empty subcommand list — we'll add commands in later phases. Compiles and runs `tasktick --help`.

- [ ] **Step 4: Verify both targets build**

Run: `swift build`
Expected: Both `TaskTick` and `tasktick` build with no warnings. Binary at `.build/debug/tasktick`.

- [ ] **Step 5: Verify CLI runs**

Run: `.build/debug/tasktick --version`
Expected: `0.1.0`

Run: `.build/debug/tasktick --help`
Expected: Brief usage message naming the command.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/CLI/ Tests/
git commit -m "cli: scaffold tasktick executable target

Adds swift-argument-parser dep, second executableTarget sharing Models/
+ a few Engine/ files via sources: whitelist (no library extraction).
Splits Tests/ into AppTests/ + CLITests/."
```

---

## Phase 1: GUI-side CLIBridge (URL Scheme + DistributedNotification receive)

### Task 1.1: Create CLIBridge with action routing

**Files:**
- Create: `Sources/Engine/CLIBridge.swift`

- [ ] **Step 1: Create CLIBridge.swift**

```swift
import AppKit
import Foundation
import SwiftData

/// Single entry point for CLI / URL-Scheme triggered actions. Both the
/// AppDelegate URL handler and the DistributedNotification observers route
/// here so the action vocabulary lives in exactly one place.
@MainActor
final class CLIBridge {

    static let shared = CLIBridge()

    enum Action: String {
        case run, stop, restart, reveal
    }

    /// Notification names: see spec §6.1
    static let runNotification     = Notification.Name("com.lifedever.TaskTick.cli.run")
    static let stopNotification    = Notification.Name("com.lifedever.TaskTick.cli.stop")
    static let restartNotification = Notification.Name("com.lifedever.TaskTick.cli.restart")
    static let revealNotification  = Notification.Name("com.lifedever.TaskTick.cli.reveal")

    private var modelContainer: ModelContainer?

    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        registerObservers()
    }

    /// Called by AppDelegate.application(_:open:) on URL Scheme launches and
    /// by DistributedNotification observers below. Idempotent — safe to call
    /// the same action twice.
    func handle(action: Action, taskId: UUID) {
        guard let container = modelContainer else {
            NSLog("⚠️ CLIBridge: handle(\(action.rawValue)) called before configure()")
            return
        }
        let context = container.mainContext
        let descriptor = FetchDescriptor<ScheduledTask>(predicate: #Predicate { $0.id == taskId })
        guard let task = try? context.fetch(descriptor).first else {
            NSLog("⚠️ CLIBridge: no task with id \(taskId)")
            return
        }

        switch action {
        case .run:
            // Already-running guard — match Quick Launcher's idempotent contract.
            guard !TaskScheduler.shared.runningTaskIDs.contains(task.id) else { return }
            Task { _ = await ScriptExecutor.shared.execute(task: task, modelContext: context) }
        case .stop:
            ScriptExecutor.shared.cancel(taskId: task.id)
        case .restart:
            let wasRunning = TaskScheduler.shared.runningTaskIDs.contains(task.id)
            if wasRunning { ScriptExecutor.shared.cancel(taskId: task.id) }
            Task {
                if wasRunning { try? await Task.sleep(for: .milliseconds(200)) }
                _ = await ScriptExecutor.shared.execute(task: task, modelContext: context)
            }
        case .reveal:
            MainWindowSelection.shared.taskToReveal = task
            NotificationCenter.default.post(name: .revealTaskInMain, object: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Parse `tasktick://run?id=<uuid>` into (action, uuid). Returns nil for
    /// malformed URLs.
    func parse(url: URL) -> (action: Action, taskId: UUID)? {
        guard url.scheme == "tasktick",
              let host = url.host,
              let action = Action(rawValue: host),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let idItem = comps.queryItems?.first(where: { $0.name == "id" }),
              let idString = idItem.value,
              let uuid = UUID(uuidString: idString) else {
            return nil
        }
        return (action, uuid)
    }

    // MARK: - DistributedNotification observers

    private func registerObservers() {
        let center = DistributedNotificationCenter.default()
        let table: [(Notification.Name, Action)] = [
            (Self.runNotification,     .run),
            (Self.stopNotification,    .stop),
            (Self.restartNotification, .restart),
            (Self.revealNotification,  .reveal)
        ]
        for (name, action) in table {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let idString = note.userInfo?["id"] as? String,
                      let uuid = UUID(uuidString: idString) else { return }
                Task { @MainActor in self?.handle(action: action, taskId: uuid) }
            }
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: builds, no warnings.

- [ ] **Step 3: Commit**

```bash
git add Sources/Engine/CLIBridge.swift
git commit -m "engine: add CLIBridge for URL Scheme + Distributed Notification routing

Single entry point for CLI-triggered actions. Both AppDelegate's URL
handler and the DistributedNotification observers funnel into the same
handle(action:taskId:) function so action vocabulary lives in one place."
```

### Task 1.2: Wire CLIBridge into AppDelegate (URL handler + boot)

**Files:**
- Modify: `Sources/App/AppDelegate.swift`
- Modify: `Sources/App/TaskTickApp.swift`

- [ ] **Step 1: Read AppDelegate.swift**

```bash
cat Sources/App/AppDelegate.swift
```

- [ ] **Step 2: Add URL handler to AppDelegate**

In `AppDelegate.swift`, add inside the AppDelegate class (after existing app-lifecycle methods):

```swift
func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
        guard let parsed = CLIBridge.shared.parse(url: url) else {
            NSLog("⚠️ AppDelegate: malformed URL \(url.absoluteString)")
            continue
        }
        CLIBridge.shared.handle(action: parsed.action, taskId: parsed.taskId)
    }
}
```

- [ ] **Step 3: Configure CLIBridge at boot in TaskTickApp.init()**

In `Sources/App/TaskTickApp.swift`, find the `init()` function (~line 18-27). Replace it with:

```swift
init() {
    let container = Self._sharedModelContainer
    let scheduler = TaskScheduler.shared
    scheduler.configure(modelContext: container.mainContext)
    scheduler.start()

    let backup = DatabaseBackup.shared
    backup.configure(storeURL: Self._storeURL, modelContext: container.mainContext)
    backup.startScheduledBackups()

    CLIBridge.shared.configure(modelContainer: container)
}
```

- [ ] **Step 4: Verify build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/AppDelegate.swift Sources/App/TaskTickApp.swift
git commit -m "app: wire CLIBridge to URL Scheme handler + app launch

AppDelegate.application(_:open:) parses tasktick:// URLs via CLIBridge.
TaskTickApp.init configures the bridge with the shared ModelContainer
so notifications received before the first window opens still work."
```

### Task 1.3: Inject URL Scheme into Info.plist

**Files:**
- Modify: `scripts/build-dev.sh`
- Modify: `scripts/release.sh`

- [ ] **Step 1: Add CFBundleURLTypes to build-dev.sh Info.plist heredoc**

In `scripts/build-dev.sh`, find the Info.plist heredoc (line 55-101). Add this block before `</dict>` (around line 99):

```xml
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.lifedever.TaskTick.dev.urlscheme</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>tasktick</string>
            </array>
        </dict>
    </array>
```

Note dev build uses `.dev.urlscheme` URL name to distinguish from release.

- [ ] **Step 2: Add CFBundleURLTypes to release.sh Info.plist heredoc**

In `scripts/release.sh`, find the Info.plist heredoc (line 88-136). Add before `</dict>`:

```xml
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.lifedever.TaskTick.urlscheme</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>tasktick</string>
            </array>
        </dict>
    </array>
```

- [ ] **Step 3: Build dev and verify URL Scheme registers**

Run: `./scripts/build-dev.sh`

Then verify:
```bash
defaults read /Applications/TaskTick\ Dev.app/Contents/Info.plist CFBundleURLTypes
```
Expected: array with one dict containing `CFBundleURLSchemes = ( tasktick )`.

- [ ] **Step 4: End-to-end smoke test the URL handler**

With TaskTick Dev running:
```bash
# Get a task UUID from the SwiftData store
sqlite3 ~/Library/Application\ Support/com.lifedever.TaskTick.dev/tasktick-dev.store \
  "SELECT ZID FROM ZSCHEDULEDTASK LIMIT 1;"
# (UUID column may be named differently; replace with the actual column)

# Open the URL
open "tasktick://run?id=<paste-uuid-here>"
```
Expected: Toast appears in TaskTick Dev showing "Task started". Menu bar icon swaps to running variant.

If the SwiftData column name isn't `ZID`, run:
```bash
sqlite3 ~/Library/Application\ Support/com.lifedever.TaskTick.dev/tasktick-dev.store \
  ".schema ZSCHEDULEDTASK" | head -20
```
to find the UUID column name.

- [ ] **Step 5: Commit**

```bash
git add scripts/build-dev.sh scripts/release.sh
git commit -m "build: register tasktick:// URL Scheme in Info.plist for both dev and release"
```

---

## Phase 2: GUI-side CLIBroadcaster (out-bound notifications)

### Task 2.1: Create CLIBroadcaster

**Files:**
- Create: `Sources/Engine/CLIBroadcaster.swift`

- [ ] **Step 1: Create CLIBroadcaster.swift**

```swift
import Combine
import Foundation
import SwiftData

/// Listens to internal task lifecycle events and rebroadcasts them as
/// Distributed Notifications so CLI subscribers (`tasktick tail`,
/// `tasktick wait`) can react without polling.
@MainActor
final class CLIBroadcaster {

    static let shared = CLIBroadcaster()

    static let taskStartedNotification   = Notification.Name("com.lifedever.TaskTick.gui.taskStarted")
    static let taskCompletedNotification = Notification.Name("com.lifedever.TaskTick.gui.taskCompleted")
    static let logChunkNotification      = Notification.Name("com.lifedever.TaskTick.gui.logChunk")

    private var cancellables: Set<AnyCancellable> = []
    private var lastRunningSnapshot: Set<UUID> = []

    func start() {
        // Watch TaskScheduler.runningTaskIDs to derive started / completed events.
        TaskScheduler.shared.$runningTaskIDs
            .removeDuplicates()
            .sink { [weak self] newIDs in
                guard let self else { return }
                self.diffAndBroadcast(newIDs: newIDs)
            }
            .store(in: &cancellables)

        // Watch LiveOutputManager for chunk events.
        LiveOutputManager.shared.chunkPublisher
            .sink { [weak self] event in
                self?.broadcastChunk(taskId: event.taskId, stream: event.stream, text: event.text)
            }
            .store(in: &cancellables)
    }

    private func diffAndBroadcast(newIDs: Set<UUID>) {
        let started = newIDs.subtracting(lastRunningSnapshot)
        let stopped = lastRunningSnapshot.subtracting(newIDs)
        lastRunningSnapshot = newIDs

        let center = DistributedNotificationCenter.default()
        let now = ISO8601DateFormatter().string(from: Date())

        for id in started {
            center.postNotificationName(
                Self.taskStartedNotification,
                object: nil,
                userInfo: ["id": id.uuidString, "startedAt": now],
                deliverImmediately: true
            )
        }

        for id in stopped {
            // Look up most recent ExecutionLog for this task to read exitCode.
            let exitCode = mostRecentExitCode(for: id)
            center.postNotificationName(
                Self.taskCompletedNotification,
                object: nil,
                userInfo: [
                    "id": id.uuidString,
                    "exitCode": exitCode ?? -1,
                    "endedAt": now
                ],
                deliverImmediately: true
            )
        }
    }

    private func broadcastChunk(taskId: UUID, stream: String, text: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Self.logChunkNotification,
            object: nil,
            userInfo: [
                "id": taskId.uuidString,
                "stream": stream,
                "text": text
            ],
            deliverImmediately: true
        )
    }

    private func mostRecentExitCode(for taskId: UUID) -> Int? {
        guard let context = TaskScheduler.shared.modelContext else { return nil }
        let descriptor = FetchDescriptor<ExecutionLog>(
            predicate: #Predicate { $0.task?.id == taskId },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        var d = descriptor
        d.fetchLimit = 1
        return (try? context.fetch(d).first)?.exitCode
    }
}
```

- [ ] **Step 2: Add chunkPublisher to LiveOutputManager**

Open `Sources/Engine/LiveOutputManager.swift`. Find where it appends stdout/stderr and expose a Combine publisher.

First read it:
```bash
cat Sources/Engine/LiveOutputManager.swift
```

Expected behavior to add (paraphrased from spec §6.4): a `PassthroughSubject<(taskId: UUID, stream: String, text: String), Never>` that fires every time a chunk arrives. If the file already has a publisher pattern matching this, reuse it; otherwise add:

```swift
struct LiveChunkEvent {
    let taskId: UUID
    let stream: String   // "stdout" or "stderr"
    let text: String
}

let chunkPublisher = PassthroughSubject<LiveChunkEvent, Never>()
```

In the existing `appendStdout(taskId:data:)` and `appendStderr(taskId:data:)` functions, after the existing logic that updates internal state, add:
```swift
chunkPublisher.send(LiveChunkEvent(
    taskId: taskId,
    stream: "stdout", // or "stderr"
    text: String(data: data, encoding: .utf8) ?? ""
))
```

- [ ] **Step 3: Start CLIBroadcaster in TaskTickApp.init**

In `Sources/App/TaskTickApp.swift`, after the `CLIBridge.shared.configure(...)` line, add:

```swift
CLIBroadcaster.shared.start()
```

- [ ] **Step 4: Verify build**

Run: `swift build`
Expected: clean.

- [ ] **Step 5: Smoke-test broadcasts**

Run TaskTick Dev. In another Terminal:
```bash
swift run --package-path /tmp/notif-test \
  python3 -c "
import subprocess
subprocess.run(['log', 'stream', '--predicate', 'subsystem == \"com.lifedever.TaskTick\"'])
"
```

Easier: write a quick observer with `osascript`:
```bash
# In Python or Swift one-liner — just confirm the notifications fire:
python3 -c "
from Foundation import NSDistributedNotificationCenter, NSObject, NSRunLoop, NSDate
class O(NSObject):
    def gotIt_(self, n): print(n.name(), dict(n.userInfo()))
o = O.new()
nc = NSDistributedNotificationCenter.defaultCenter()
for name in ['com.lifedever.TaskTick.gui.taskStarted','com.lifedever.TaskTick.gui.taskCompleted','com.lifedever.TaskTick.gui.logChunk']:
    nc.addObserver_selector_name_object_(o, 'gotIt:', name, None)
NSRunLoop.currentRunLoop().runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(60))
"
```

Then run a task in TaskTick Dev. Expected: the script prints `taskStarted` and (after the task finishes) `taskCompleted` with the task's UUID.

- [ ] **Step 6: Commit**

```bash
git add Sources/Engine/CLIBroadcaster.swift Sources/Engine/LiveOutputManager.swift Sources/App/TaskTickApp.swift
git commit -m "engine: broadcast task lifecycle events as Distributed Notifications

Mirrors TaskScheduler.runningTaskIDs into started/completed events and
LiveOutputManager chunks into logChunk events. CLI tail/wait subscribe."
```

---

## Phase 3: CLI infrastructure (ReadOnlyStore, TaskResolver, DTOs)

### Task 3.1: TDD TaskDTO Codable

**Files:**
- Create: `Sources/CLI/Output/TaskDTO.swift`
- Create: `Tests/CLITests/TaskDTOTests.swift`

- [ ] **Step 1: Write failing test**

Create `Tests/CLITests/TaskDTOTests.swift`:

```swift
import XCTest
@testable import tasktick

final class TaskDTOTests: XCTestCase {
    func testEncodesTaskWithAllFields() throws {
        let dto = TaskDTO(
            id: UUID(uuidString: "A3F9C200-0000-0000-0000-000000000000")!,
            shortId: "a3f9",
            name: "Deploy Web",
            kind: .scheduled,
            enabled: true,
            status: .idle,
            scheduleSummary: "Daily at 09:00",
            lastRunAt: Date(timeIntervalSince1970: 1_715_175_121),
            lastRunDurationSec: 47,
            lastExitCode: 0,
            createdAt: Date(timeIntervalSince1970: 1_711_966_800)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(dto)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("\"id\":\"A3F9C200-0000-0000-0000-000000000000\""))
        XCTAssertTrue(json.contains("\"shortId\":\"a3f9\""))
        XCTAssertTrue(json.contains("\"kind\":\"scheduled\""))
        XCTAssertTrue(json.contains("\"status\":\"idle\""))
    }

    func testRoundTripIdleTaskWithNoLastRun() throws {
        let dto = TaskDTO(
            id: UUID(),
            shortId: "abcd",
            name: "Untouched",
            kind: .manual,
            enabled: false,
            status: .idle,
            scheduleSummary: "Manual",
            lastRunAt: nil,
            lastRunDurationSec: nil,
            lastExitCode: nil,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let roundTripped = try decoder.decode(TaskDTO.self, from: encoder.encode(dto))
        XCTAssertEqual(roundTripped.id, dto.id)
        XCTAssertNil(roundTripped.lastRunAt)
        XCTAssertEqual(roundTripped.kind, .manual)
    }
}
```

- [ ] **Step 2: Run test (expected to fail — TaskDTO doesn't exist)**

Run: `swift test --filter CLITests.TaskDTOTests`
Expected: FAIL with "Cannot find 'TaskDTO' in scope"

- [ ] **Step 3: Implement TaskDTO**

Create `Sources/CLI/Output/TaskDTO.swift`:

```swift
import Foundation

enum TaskKind: String, Codable {
    case scheduled
    case manual
}

enum TaskStatus: String, Codable {
    case idle
    case running
}

struct TaskDTO: Codable {
    let id: UUID
    let shortId: String
    let name: String
    let kind: TaskKind
    let enabled: Bool
    let status: TaskStatus
    let scheduleSummary: String
    let lastRunAt: Date?
    let lastRunDurationSec: Int?
    let lastExitCode: Int?
    let createdAt: Date
}

struct StatusGlobalDTO: Codable {
    struct RunningTask: Codable {
        let id: UUID
        let name: String
        let startedAt: Date
        let elapsedSec: Int
    }
    let running: [RunningTask]
    let totalEnabled: Int
    let totalRunning: Int
}

struct ExecutionLogDTO: Codable {
    struct LogLine: Codable {
        let ts: Date
        let stream: String  // "stdout" | "stderr"
        let text: String
    }
    let executionId: UUID
    let taskId: UUID
    let startedAt: Date
    let endedAt: Date?
    let exitCode: Int?
    let stdout: String
    let stderr: String
    let lines: [LogLine]
}
```

- [ ] **Step 4: Run test (expected to pass)**

Run: `swift test --filter CLITests.TaskDTOTests`
Expected: PASS, both tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/CLI/Output/TaskDTO.swift Tests/CLITests/TaskDTOTests.swift
git commit -m "cli: add Codable DTOs for tasks, status, execution logs

Schema matches spec §5.4. Used by --json output across list/status/logs
and consumed by the Raycast extension."
```

### Task 3.2: TDD TaskResolver

**Files:**
- Create: `Sources/CLI/Identifier/TaskResolver.swift`
- Create: `Tests/CLITests/TaskResolverTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import tasktick

final class TaskResolverTests: XCTestCase {
    private struct Sample {
        let id: UUID
        let name: String
    }

    private let samples: [Sample] = [
        .init(id: UUID(uuidString: "A3F9C200-0000-0000-0000-000000000001")!, name: "Deploy Web"),
        .init(id: UUID(uuidString: "B1C40000-0000-0000-0000-000000000002")!, name: "Backup Photos"),
        .init(id: UUID(uuidString: "C7E20000-0000-0000-0000-000000000003")!, name: "Sync Vault")
    ]

    private func resolver() -> TaskResolver<Sample> {
        TaskResolver(items: samples, idOf: { $0.id }, nameOf: { $0.name })
    }

    func testResolvesByFullUUID() throws {
        let r = try resolver().resolve("A3F9C200-0000-0000-0000-000000000001")
        XCTAssertEqual(r.name, "Deploy Web")
    }

    func testResolvesByShortIdPrefix() throws {
        let r = try resolver().resolve("a3f9")
        XCTAssertEqual(r.name, "Deploy Web")
    }

    func testResolvesByExactName() throws {
        let r = try resolver().resolve("Backup Photos")
        XCTAssertEqual(r.id.uuidString, "B1C40000-0000-0000-0000-000000000002")
    }

    func testResolvesByCaseInsensitiveName() throws {
        let r = try resolver().resolve("backup photos")
        XCTAssertEqual(r.id.uuidString, "B1C40000-0000-0000-0000-000000000002")
    }

    func testResolvesByFuzzy() throws {
        let r = try resolver().resolve("depl")
        XCTAssertEqual(r.name, "Deploy Web")
    }

    func testThrowsOnNoMatch() {
        XCTAssertThrowsError(try resolver().resolve("zzzz")) { error in
            guard case TaskResolverError.noMatch(let q) = error else {
                XCTFail("expected noMatch, got \(error)"); return
            }
            XCTAssertEqual(q, "zzzz")
        }
    }

    func testThrowsOnMultipleMatches() {
        // Both "Deploy Web" and "Deploy Mobile" — add a temporary duplicate.
        let extra = Sample(id: UUID(), name: "Deploy Mobile")
        let r = TaskResolver(items: samples + [extra], idOf: { $0.id }, nameOf: { $0.name })
        XCTAssertThrowsError(try r.resolve("deploy")) { error in
            guard case TaskResolverError.ambiguous(let candidates) = error else {
                XCTFail("expected ambiguous, got \(error)"); return
            }
            XCTAssertEqual(candidates.count, 2)
        }
    }
}
```

- [ ] **Step 2: Run test (expected to fail)**

Run: `swift test --filter CLITests.TaskResolverTests`
Expected: FAIL with "Cannot find 'TaskResolver' in scope"

- [ ] **Step 3: Implement TaskResolver**

Create `Sources/CLI/Identifier/TaskResolver.swift`:

```swift
import Foundation

enum TaskResolverError: Error, CustomStringConvertible {
    case noMatch(String)
    case ambiguous([(id: UUID, name: String)])

    var description: String {
        switch self {
        case .noMatch(let q):
            return "no task matches \"\(q)\""
        case .ambiguous(let cs):
            let lines = cs.map { c in
                "  \(String(c.id.uuidString.prefix(4)).lowercased()) \(c.name)"
            }.joined(separator: "\n")
            return "multiple matches:\n\(lines)\nbe more specific."
        }
    }
}

/// Multi-tier identifier resolver. Generic over the item type so it can be
/// unit-tested without standing up SwiftData.
struct TaskResolver<Item> {
    let items: [Item]
    let idOf: (Item) -> UUID
    let nameOf: (Item) -> String

    /// 1. UUID full match
    /// 2. UUID prefix match (≥4 chars)
    /// 3. Name case-insensitive exact match
    /// 4. Fuzzy name match (FuzzyMatch.score)
    /// Throws .noMatch on zero hits, .ambiguous on multi-hit at any tier.
    func resolve(_ query: String) throws -> Item {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { throw TaskResolverError.noMatch(query) }

        // Tier 1: UUID full match
        if let uuid = UUID(uuidString: q) {
            if let hit = items.first(where: { idOf($0) == uuid }) {
                return hit
            }
            throw TaskResolverError.noMatch(query)
        }

        // Tier 2: UUID prefix (≥4 hex chars, normalize to lowercase)
        let lowered = q.lowercased()
        if lowered.count >= 4, lowered.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            let prefixHits = items.filter { idOf($0).uuidString.lowercased().hasPrefix(lowered) }
            if prefixHits.count == 1 { return prefixHits[0] }
            if prefixHits.count > 1 { throw ambiguousError(prefixHits) }
        }

        // Tier 3: Exact name (case-insensitive)
        let exactHits = items.filter { nameOf($0).lowercased() == lowered }
        if exactHits.count == 1 { return exactHits[0] }
        if exactHits.count > 1 { throw ambiguousError(exactHits) }

        // Tier 4: Fuzzy name match — score every candidate, keep top.
        let scored = items.compactMap { item -> (item: Item, score: Int)? in
            guard let s = FuzzyMatch.score(query: q, candidate: nameOf(item)) else { return nil }
            return (item, s)
        }
        guard !scored.isEmpty else { throw TaskResolverError.noMatch(query) }
        let topScore = scored.map(\.score).max()!
        let topMatches = scored.filter { $0.score == topScore }.map(\.item)
        if topMatches.count == 1 { return topMatches[0] }
        throw ambiguousError(topMatches)
    }

    private func ambiguousError(_ items: [Item]) -> TaskResolverError {
        .ambiguous(items.map { (id: idOf($0), name: nameOf($0)) })
    }
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self.lowercased().first!)
    }
}
```

- [ ] **Step 4: Run test (expected to pass)**

Run: `swift test --filter CLITests.TaskResolverTests`
Expected: PASS, all 7 tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/CLI/Identifier/TaskResolver.swift Tests/CLITests/TaskResolverTests.swift
git commit -m "cli: add TaskResolver with UUID/prefix/name/fuzzy tiered matching

Generic over the item type so it tests without SwiftData. Throws
.ambiguous with the candidate list — surfaced verbatim by the CLI."
```

### Task 3.3: ReadOnlyStore wrapper

**Files:**
- Create: `Sources/CLI/Bridge/ReadOnlyStore.swift`
- Create: `Tests/CLITests/ReadOnlyStoreTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
import SwiftData
@testable import tasktick

final class ReadOnlyStoreTests: XCTestCase {

    func testOpensExistingStoreAndFetchesTasks() throws {
        // Set up a temp store with one task.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tasktick-cli-test-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            let schema = Schema([ScheduledTask.self, ExecutionLog.self])
            let cfg = ModelConfiguration(schema: schema, url: tmp, allowsSave: true)
            let container = try ModelContainer(for: schema, configurations: [cfg])
            let ctx = container.mainContext
            ctx.insert(ScheduledTask(name: "Test Task"))
            try ctx.save()
        }

        // Open it read-only via ReadOnlyStore.
        let store = try ReadOnlyStore(url: tmp)
        let tasks = try store.fetchTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.name, "Test Task")
    }

    func testOpensEmptyStoreWithoutCrashing() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tasktick-cli-empty-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = try ReadOnlyStore(url: tmp)
        let tasks = try store.fetchTasks()
        XCTAssertEqual(tasks.count, 0)
    }
}
```

- [ ] **Step 2: Run test (fails)**

Run: `swift test --filter CLITests.ReadOnlyStoreTests`
Expected: FAIL "Cannot find 'ReadOnlyStore'"

- [ ] **Step 3: Implement ReadOnlyStore**

Create `Sources/CLI/Bridge/ReadOnlyStore.swift`:

```swift
import Foundation
import SwiftData

/// Read-only wrapper around a SwiftData ModelContainer. CLI commands use this
/// to query the same store TaskTick.app writes to without ever risking a
/// concurrent write from the CLI side.
final class ReadOnlyStore {
    let container: ModelContainer

    init(url: URL? = nil) throws {
        // Default to the bundle-namespaced store path the GUI uses.
        let storeURL = url ?? StoreMigration.resolveStoreURL()
        // Checkpoint any -wal sidecar from the GUI before we open. Concurrent
        // SQLite reads work fine, but if the GUI just wrote and the WAL hasn't
        // been merged, our read might miss the latest data.
        StoreHardener.hardenStore(at: storeURL)

        let schema = Schema([ScheduledTask.self, ExecutionLog.self])
        let cfg = ModelConfiguration(
            schema: schema,
            url: storeURL,
            allowsSave: false  // ← CLI never writes
        )
        self.container = try ModelContainer(for: schema, configurations: [cfg])
    }

    func fetchTasks() throws -> [ScheduledTask] {
        let descriptor = FetchDescriptor<ScheduledTask>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try container.mainContext.fetch(descriptor)
    }

    func fetchTask(byId id: UUID) throws -> ScheduledTask? {
        let descriptor = FetchDescriptor<ScheduledTask>(predicate: #Predicate { $0.id == id })
        return try container.mainContext.fetch(descriptor).first
    }

    func fetchLatestLog(forTaskId taskId: UUID) throws -> ExecutionLog? {
        var descriptor = FetchDescriptor<ExecutionLog>(
            predicate: #Predicate { $0.task?.id == taskId },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try container.mainContext.fetch(descriptor).first
    }
}
```

- [ ] **Step 4: Run test (passes)**

Run: `swift test --filter CLITests.ReadOnlyStoreTests`
Expected: PASS, both tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/CLI/Bridge/ReadOnlyStore.swift Tests/CLITests/ReadOnlyStoreTests.swift
git commit -m "cli: ReadOnlyStore wraps ModelContainer with allowsSave: false

CLI never writes; this enforces it at SwiftData level. WAL is
checkpointed via StoreHardener so reads see the GUI's latest writes."
```

---

## Phase 4: CLI Read commands (list, status, logs)

### Task 4.1: ListCommand

**Files:**
- Create: `Sources/CLI/Commands/ListCommand.swift`
- Create: `Sources/CLI/Output/TableRenderer.swift`
- Modify: `Sources/CLI/main.swift`

- [ ] **Step 1: Create TableRenderer**

```swift
import Foundation

/// Minimal column-aligned table renderer (no third-party dep). Computes column
/// widths from content, prints header in caps, single-line rows.
enum TableRenderer {
    static func render(headers: [String], rows: [[String]]) -> String {
        guard !headers.isEmpty else { return "" }
        var widths = headers.map { $0.count }
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }

        func formatRow(_ cells: [String]) -> String {
            zip(cells, widths)
                .map { cell, w in cell.padding(toLength: w, withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }

        var lines: [String] = [formatRow(headers)]
        for row in rows {
            // Pad short rows with empty strings to match column count.
            var padded = row
            while padded.count < headers.count { padded.append("") }
            lines.append(formatRow(padded))
        }
        return lines.joined(separator: "\n")
    }
}
```

- [ ] **Step 2: Add a TaskDTO factory from ScheduledTask**

Append to `Sources/CLI/Output/TaskDTO.swift`:

```swift
extension TaskDTO {
    /// Build from a SwiftData ScheduledTask + the current running ID set.
    /// `runningIds` must be supplied separately because a CLI process can't
    /// observe the GUI's @Published runningTaskIDs (different process).
    static func from(_ task: ScheduledTask, runningIds: Set<UUID>, lastLog: ExecutionLog?) -> TaskDTO {
        TaskDTO(
            id: task.id,
            shortId: String(task.id.uuidString.prefix(4)).lowercased(),
            name: task.name,
            kind: task.isManualOnly ? .manual : .scheduled,
            enabled: task.isEnabled,
            status: runningIds.contains(task.id) ? .running : .idle,
            scheduleSummary: task.isManualOnly ? "Manual" : task.repeatType.displayName,
            lastRunAt: task.lastRunAt,
            lastRunDurationSec: lastLog?.durationMs.map { $0 / 1000 },
            lastExitCode: lastLog?.exitCode,
            createdAt: task.createdAt
        )
    }
}
```

- [ ] **Step 3: Add `runningTaskIds()` helper to NotificationBridge stub**

Create `Sources/CLI/Bridge/NotificationBridge.swift`:

```swift
import AppKit
import Foundation

/// Distributed Notification helpers. Only post + observe primitives — the
/// command-specific logic stays in each Command class.
enum NotificationBridge {

    enum CLIAction: String {
        case run, stop, restart, reveal

        var notificationName: Notification.Name {
            Notification.Name("com.lifedever.TaskTick.cli.\(rawValue)")
        }
    }

    /// Post a CLI → GUI command notification.
    static func post(action: CLIAction, taskId: UUID) {
        DistributedNotificationCenter.default().postNotificationName(
            action.notificationName,
            object: nil,
            userInfo: ["id": taskId.uuidString],
            deliverImmediately: true
        )
    }

    /// Best-effort snapshot of currently-running task IDs. Implemented by
    /// requesting a fresh status broadcast — but for now (Phase 4) the CLI
    /// reads ExecutionLog rows where status == .running as a proxy. This is
    /// "stale" by 1 fetch round-trip but correct after the GUI's last save.
    /// Phase 6 (tail/wait) replaces this with a live observer.
    static func runningTaskIds(store: ReadOnlyStore) -> Set<UUID> {
        let container = store.container
        let descriptor = FetchDescriptor<ExecutionLog>(
            predicate: #Predicate { $0.statusRaw == "running" }
        )
        let logs = (try? container.mainContext.fetch(descriptor)) ?? []
        return Set(logs.compactMap { $0.task?.id })
    }
}
```

- [ ] **Step 4: Create ListCommand**

Create `Sources/CLI/Commands/ListCommand.swift`:

```swift
import ArgumentParser
import Foundation
import SwiftData

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List tasks (default: all enabled)."
    )

    enum Filter: String, ExpressibleByArgument {
        case all, manual, scheduled, running
    }

    @Option(name: .long, help: "Filter: all | manual | scheduled | running")
    var filter: Filter = .all

    @Flag(name: .long, help: "Output JSON instead of a human-readable table.")
    var json: Bool = false

    func run() async throws {
        let store = try ReadOnlyStore()
        let runningIds = NotificationBridge.runningTaskIds(store: store)
        let allTasks = try store.fetchTasks()

        let filtered = allTasks.filter { task in
            switch filter {
            case .all: return task.isEnabled
            case .manual: return task.isEnabled && task.isManualOnly
            case .scheduled: return task.isEnabled && !task.isManualOnly
            case .running: return runningIds.contains(task.id)
            }
        }

        let dtos: [TaskDTO] = filtered.map { task in
            let lastLog = try? store.fetchLatestLog(forTaskId: task.id)
            return TaskDTO.from(task, runningIds: runningIds, lastLog: lastLog ?? nil)
        }

        if json {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(dtos)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let rows = dtos.map { dto in
                [
                    dto.shortId,
                    dto.name,
                    dto.kind.rawValue,
                    dto.status.rawValue,
                    dto.lastRunAt.map { formatter.localizedString(for: $0, relativeTo: Date()) } ?? "—"
                ]
            }
            print(TableRenderer.render(
                headers: ["ID", "NAME", "KIND", "STATUS", "LAST RUN"],
                rows: rows
            ))
        }
    }
}
```

- [ ] **Step 5: Wire ListCommand into main.swift**

Update `Sources/CLI/main.swift`:

```swift
import ArgumentParser
import Foundation

@main
struct TaskTick: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tasktick",
        abstract: "Control TaskTick scheduled tasks from the command line.",
        version: "0.1.0",
        subcommands: [
            ListCommand.self
        ]
    )
}
```

- [ ] **Step 6: Verify**

Run: `swift build && .build/debug/tasktick list`
Expected: table output with columns ID/NAME/KIND/STATUS/LAST RUN, populated from the actual TaskTick store.

Run: `.build/debug/tasktick list --json | jq .`
Expected: JSON array of task objects.

Run: `.build/debug/tasktick list --filter running`
Expected: only tasks currently running (probably empty if nothing was started recently).

- [ ] **Step 7: Commit**

```bash
git add Sources/CLI/
git commit -m "cli: implement list command with --filter and --json"
```

### Task 4.2: StatusCommand

**Files:**
- Create: `Sources/CLI/Commands/StatusCommand.swift`
- Modify: `Sources/CLI/main.swift`

- [ ] **Step 1: Create StatusCommand**

```swift
import ArgumentParser
import Foundation

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show running tasks (no arg: global summary; with arg: single task)."
    )

    @Argument(help: "Task identifier (UUID, prefix, name, or fuzzy).")
    var identifier: String?

    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let store = try ReadOnlyStore()
        let runningIds = NotificationBridge.runningTaskIds(store: store)
        let allTasks = try store.fetchTasks()

        if let id = identifier {
            let resolver = TaskResolver(items: allTasks, idOf: { $0.id }, nameOf: { $0.name })
            let task: ScheduledTask
            do {
                task = try resolver.resolve(id)
            } catch let err as TaskResolverError {
                FileHandle.standardError.write(Data("tasktick: \(err)\n".utf8))
                throw ExitCode(1)
            }
            let lastLog = try? store.fetchLatestLog(forTaskId: task.id)
            let dto = TaskDTO.from(task, runningIds: runningIds, lastLog: lastLog ?? nil)
            if json {
                try printJSON(dto)
            } else {
                print("\(dto.shortId)  \(dto.name)  [\(dto.status.rawValue)]")
            }
            return
        }

        // Global summary
        let runningTasks = allTasks.filter { runningIds.contains($0.id) }
        let runningDTOs: [StatusGlobalDTO.RunningTask] = runningTasks.compactMap { task in
            guard let log = try? store.fetchLatestLog(forTaskId: task.id) else { return nil }
            let elapsed = Int(Date().timeIntervalSince(log.startedAt))
            return .init(id: task.id, name: task.name, startedAt: log.startedAt, elapsedSec: elapsed)
        }
        let global = StatusGlobalDTO(
            running: runningDTOs,
            totalEnabled: allTasks.filter(\.isEnabled).count,
            totalRunning: runningDTOs.count
        )

        if json {
            try printJSON(global)
        } else {
            print("Enabled: \(global.totalEnabled)  Running: \(global.totalRunning)")
            for t in runningDTOs {
                print("  \(t.name) — \(t.elapsedSec)s")
            }
        }
    }

    private func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        print(String(data: data, encoding: .utf8) ?? "{}")
    }
}
```

- [ ] **Step 2: Wire into main.swift**

Add `StatusCommand.self` to the `subcommands:` array in `main.swift`.

- [ ] **Step 3: Verify**

Run: `swift build && .build/debug/tasktick status`
Expected: `Enabled: N  Running: 0` (or list any running task).

Run: `.build/debug/tasktick status "Hello TaskTick"`
Expected: one line with shortId/name/status.

Run: `.build/debug/tasktick status nonexistent`
Expected: stderr `tasktick: no task matches "nonexistent"`, exit 1.

- [ ] **Step 4: Commit**

```bash
git add Sources/CLI/Commands/StatusCommand.swift Sources/CLI/main.swift
git commit -m "cli: implement status command (global + single task)"
```

### Task 4.3: LogsCommand

**Files:**
- Create: `Sources/CLI/Commands/LogsCommand.swift`
- Modify: `Sources/CLI/main.swift`

- [ ] **Step 1: Create LogsCommand**

```swift
import ArgumentParser
import Foundation

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Show the most recent execution log for a task."
    )

    @Argument(help: "Task identifier.")
    var identifier: String

    @Option(name: .long, help: "Number of lines from the end to show (0 = all).")
    var lines: Int = 0

    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let store = try ReadOnlyStore()
        let allTasks = try store.fetchTasks()
        let resolver = TaskResolver(items: allTasks, idOf: { $0.id }, nameOf: { $0.name })

        let task: ScheduledTask
        do {
            task = try resolver.resolve(identifier)
        } catch let err as TaskResolverError {
            FileHandle.standardError.write(Data("tasktick: \(err)\n".utf8))
            throw ExitCode(1)
        }

        guard let log = try store.fetchLatestLog(forTaskId: task.id) else {
            FileHandle.standardError.write(Data("tasktick: no execution logs for \(task.name)\n".utf8))
            throw ExitCode(1)
        }

        if json {
            let dto = ExecutionLogDTO(
                executionId: log.id,
                taskId: task.id,
                startedAt: log.startedAt,
                endedAt: log.finishedAt,
                exitCode: log.exitCode,
                stdout: log.stdout ?? "",
                stderr: log.stderr ?? "",
                lines: []  // Per-line timestamps not tracked in current schema; spec future-proofs the field.
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(dto)
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }

        // Human-readable: combine stdout + stderr with stream label, truncate to --lines.
        var out: [String] = []
        if let stdout = log.stdout, !stdout.isEmpty {
            out.append(contentsOf: stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        }
        if let stderr = log.stderr, !stderr.isEmpty {
            for line in stderr.split(separator: "\n", omittingEmptySubsequences: false) {
                out.append("[stderr] \(line)")
            }
        }
        if lines > 0 && out.count > lines {
            out = Array(out.suffix(lines))
        }
        print(out.joined(separator: "\n"))
    }
}
```

- [ ] **Step 2: Wire into main.swift**

Add `LogsCommand.self` to subcommands.

- [ ] **Step 3: Verify**

Run: `.build/debug/tasktick logs "Hello TaskTick"` (assuming the seed task has at least one execution).
Expected: prints stdout content of last execution.

Run: `.build/debug/tasktick logs "Hello TaskTick" --json | jq .stdout`
Expected: JSON-quoted stdout string.

- [ ] **Step 4: Commit**

```bash
git add Sources/CLI/Commands/LogsCommand.swift Sources/CLI/main.swift
git commit -m "cli: implement logs command"
```

---

## Phase 5: CLI Write commands (run, stop, restart, reveal)

### Task 5.1: GUILauncher

**Files:**
- Create: `Sources/CLI/Bridge/GUILauncher.swift`

- [ ] **Step 1: Create GUILauncher**

```swift
import AppKit
import Foundation

/// Detects whether TaskTick.app is running, launches it via URL Scheme if not,
/// and waits up to 10s for it to be ready before returning.
enum GUILauncher {

    /// Bundle IDs to look for. Includes the dev variant so `tasktick` invoked
    /// during development still works against TaskTick Dev.app.
    private static let bundleIds = ["com.lifedever.TaskTick", "com.lifedever.TaskTick.dev"]

    static func isRunning() -> Bool {
        bundleIds.contains { id in
            !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
        }
    }

    /// Launch TaskTick by opening a URL. Used as fallback when the GUI isn't
    /// running and a write command needs to dispatch. Blocks up to 10s for the
    /// app to be running. Returns whether launch succeeded.
    static func launchAndWait(action: NotificationBridge.CLIAction, taskId: UUID, timeout: TimeInterval = 10) -> Bool {
        guard let url = URL(string: "tasktick://\(action.rawValue)?id=\(taskId.uuidString)") else {
            return false
        }
        NSWorkspace.shared.open(url)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}
```

- [ ] **Step 2: Verify**

Run: `swift build`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/CLI/Bridge/GUILauncher.swift
git commit -m "cli: GUILauncher detects/launches/waits for TaskTick.app"
```

### Task 5.2: RunCommand (template for stop/restart/reveal)

**Files:**
- Create: `Sources/CLI/Commands/RunCommand.swift`
- Modify: `Sources/CLI/main.swift`

- [ ] **Step 1: Create RunCommand**

```swift
import ArgumentParser
import Foundation

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start a task. Wakes TaskTick.app if not running."
    )

    @Argument(help: "Task identifier.")
    var identifier: String

    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        try await dispatch(action: .run, identifier: identifier, json: json)
    }
}

/// Shared dispatch logic for run/stop/restart/reveal — they only differ by
/// CLIAction enum value and the success message verb.
@MainActor
func dispatch(action: NotificationBridge.CLIAction, identifier: String, json: Bool) async throws {
    let store = try ReadOnlyStore()
    let allTasks = try store.fetchTasks()
    let resolver = TaskResolver(items: allTasks, idOf: { $0.id }, nameOf: { $0.name })

    let task: ScheduledTask
    do {
        task = try resolver.resolve(identifier)
    } catch let err as TaskResolverError {
        FileHandle.standardError.write(Data("tasktick: \(err)\n".utf8))
        throw ExitCode(1)
    }

    // Idempotency: already-running guard for run, idle guard for stop.
    let runningIds = NotificationBridge.runningTaskIds(store: store)
    let isRunning = runningIds.contains(task.id)
    switch action {
    case .run where isRunning:
        FileHandle.standardError.write(Data("note: already running\n".utf8))
        printSuccess(action: action, name: task.name, json: json)
        return
    case .stop where !isRunning:
        FileHandle.standardError.write(Data("note: not running\n".utf8))
        printSuccess(action: action, name: task.name, json: json)
        return
    default:
        break
    }

    if GUILauncher.isRunning() {
        NotificationBridge.post(action: action, taskId: task.id)
    } else {
        // Wake the GUI and let it process the URL Scheme directly.
        let ok = GUILauncher.launchAndWait(action: action, taskId: task.id)
        if !ok {
            FileHandle.standardError.write(Data("tasktick: TaskTick.app failed to launch within 10s\n".utf8))
            throw ExitCode(1)
        }
    }
    printSuccess(action: action, name: task.name, json: json)
}

private func printSuccess(action: NotificationBridge.CLIAction, name: String, json: Bool) {
    if json {
        let payload: [String: String] = [
            "id": action.rawValue,
            "status": {
                switch action {
                case .run: return "started"
                case .stop: return "stopped"
                case .restart: return "restarted"
                case .reveal: return "revealed"
                }
            }(),
            "name": name
        ]
        let data = try? JSONEncoder().encode(payload)
        print(String(data: data ?? Data(), encoding: .utf8) ?? "{}")
    } else {
        let verb: String = {
            switch action {
            case .run: return "Started"
            case .stop: return "Stopped"
            case .restart: return "Restarted"
            case .reveal: return "Revealed in TaskTick"
            }
        }()
        print("✓ \(verb): \(name)")
    }
}
```

- [ ] **Step 2: Wire into main.swift**

```swift
subcommands: [
    ListCommand.self,
    StatusCommand.self,
    LogsCommand.self,
    RunCommand.self
]
```

- [ ] **Step 3: Verify run**

Build dev TaskTick first to ensure URL Scheme is in Info.plist:
```bash
./scripts/build-dev.sh
```

Then:
```bash
swift build
.build/debug/tasktick run "Hello TaskTick"
```
Expected: `✓ Started: Hello TaskTick`. TaskTick Dev menu bar shows running indicator briefly.

```bash
.build/debug/tasktick run "Hello TaskTick" --json
```
Expected: JSON `{"id":"run","name":"Hello TaskTick","status":"started"}`

```bash
# With TaskTick Dev quit, this should auto-launch it:
pkill -f "TaskTick Dev"
sleep 1
.build/debug/tasktick run "Hello TaskTick"
```
Expected: TaskTick Dev launches, then `✓ Started: Hello TaskTick`.

- [ ] **Step 4: Commit**

```bash
git add Sources/CLI/Commands/RunCommand.swift Sources/CLI/main.swift
git commit -m "cli: implement run command with idempotent already-running handling

Auto-wakes TaskTick.app via URL Scheme when not running. Shared dispatch
helper used by stop/restart/reveal in subsequent commits."
```

### Task 5.3: Stop / Restart / Reveal commands

**Files:**
- Create: `Sources/CLI/Commands/StopCommand.swift`
- Create: `Sources/CLI/Commands/RestartCommand.swift`
- Create: `Sources/CLI/Commands/RevealCommand.swift`
- Modify: `Sources/CLI/main.swift`

- [ ] **Step 1: Create StopCommand**

```swift
import ArgumentParser
import Foundation

struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop a running task."
    )

    @Argument(help: "Task identifier.")
    var identifier: String

    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        try await dispatch(action: .stop, identifier: identifier, json: json)
    }
}
```

- [ ] **Step 2: Create RestartCommand**

```swift
import ArgumentParser
import Foundation

struct RestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Stop and immediately re-run a task."
    )

    @Argument(help: "Task identifier.")
    var identifier: String

    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        try await dispatch(action: .restart, identifier: identifier, json: json)
    }
}
```

- [ ] **Step 3: Create RevealCommand**

```swift
import ArgumentParser
import Foundation

struct RevealCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reveal",
        abstract: "Open the TaskTick main window with this task selected."
    )

    @Argument(help: "Task identifier.")
    var identifier: String

    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        try await dispatch(action: .reveal, identifier: identifier, json: json)
    }
}
```

- [ ] **Step 4: Wire all three into main.swift**

```swift
subcommands: [
    ListCommand.self,
    StatusCommand.self,
    LogsCommand.self,
    RunCommand.self,
    StopCommand.self,
    RestartCommand.self,
    RevealCommand.self
]
```

- [ ] **Step 5: Verify each**

```bash
swift build
.build/debug/tasktick run "Hello TaskTick"
sleep 1
.build/debug/tasktick stop "Hello TaskTick"
.build/debug/tasktick restart "Hello TaskTick"
.build/debug/tasktick reveal "Hello TaskTick"
```
Expected:
- stop → `✓ Stopped: Hello TaskTick`, GUI menu bar icon returns to idle
- restart → `✓ Restarted: Hello TaskTick`, task runs again from scratch
- reveal → `✓ Revealed in TaskTick: Hello TaskTick`, TaskTick Dev main window opens with that task highlighted

- [ ] **Step 6: Commit**

```bash
git add Sources/CLI/Commands/{Stop,Restart,Reveal}Command.swift Sources/CLI/main.swift
git commit -m "cli: implement stop, restart, reveal commands

All four write commands now share dispatch() helper from run.swift —
just enum value differs."
```

---

## Phase 6: CLI Stream commands (tail, wait)

### Task 6.1: TailCommand

**Files:**
- Create: `Sources/CLI/Commands/TailCommand.swift`
- Modify: `Sources/CLI/main.swift`

- [ ] **Step 1: Create TailCommand**

```swift
import ArgumentParser
import Foundation

struct TailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tail",
        abstract: "Stream a running task's stdout/stderr in real time."
    )

    @Argument(help: "Task identifier.")
    var identifier: String

    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let store = try ReadOnlyStore()
        let allTasks = try store.fetchTasks()
        let resolver = TaskResolver(items: allTasks, idOf: { $0.id }, nameOf: { $0.name })
        let task: ScheduledTask
        do {
            task = try resolver.resolve(identifier)
        } catch let err as TaskResolverError {
            FileHandle.standardError.write(Data("tasktick: \(err)\n".utf8))
            throw ExitCode(1)
        }

        // Refuse early if the task isn't currently running — there's nothing
        // to stream.
        let runningIds = NotificationBridge.runningTaskIds(store: store)
        guard runningIds.contains(task.id) else {
            FileHandle.standardError.write(Data("tasktick: \(task.name) is not running\n".utf8))
            throw ExitCode(1)
        }

        // Subscribe to chunk + completed notifications.
        let center = DistributedNotificationCenter.default()
        let chunkName     = Notification.Name("com.lifedever.TaskTick.gui.logChunk")
        let completedName = Notification.Name("com.lifedever.TaskTick.gui.taskCompleted")
        let targetId = task.id.uuidString

        // Use a Continuation to bridge Distributed Notifications into async/await.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Install signal handler for Ctrl+C → exit 130.
            signal(SIGINT, SIG_IGN)
            let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigSrc.setEventHandler {
                cont.resume(throwing: ExitCode(130))
            }
            sigSrc.resume()

            var observers: [NSObjectProtocol] = []

            observers.append(center.addObserver(forName: chunkName, object: nil, queue: .main) { note in
                guard
                    let info = note.userInfo,
                    let id = info["id"] as? String,
                    id == targetId,
                    let stream = info["stream"] as? String,
                    let text = info["text"] as? String
                else { return }
                if json {
                    let payload: [String: String] = ["stream": stream, "text": text]
                    if let data = try? JSONEncoder().encode(payload),
                       let line = String(data: data, encoding: .utf8) {
                        print(line)
                    }
                } else {
                    let prefix = (stream == "stderr") ? "[stderr] " : ""
                    print(prefix + text, terminator: "")
                }
            })

            observers.append(center.addObserver(forName: completedName, object: nil, queue: .main) { note in
                guard let id = note.userInfo?["id"] as? String, id == targetId else { return }
                for o in observers { center.removeObserver(o) }
                sigSrc.cancel()
                cont.resume(returning: ())
            })
        }
    }
}
```

- [ ] **Step 2: Wire into main.swift**

Add `TailCommand.self` to subcommands.

- [ ] **Step 3: Verify**

In Terminal A:
```bash
.build/debug/tasktick run "Hello TaskTick"
```

Quickly switch to Terminal B (within ~3s while task runs):
```bash
.build/debug/tasktick tail "Hello TaskTick"
```
Expected: prints "Hello from TaskTick! 🎉" lines as they're emitted, then exits when task completes.

- [ ] **Step 4: Commit**

```bash
git add Sources/CLI/Commands/TailCommand.swift Sources/CLI/main.swift
git commit -m "cli: implement tail command (real-time stdout/stderr stream)"
```

### Task 6.2: WaitCommand

**Files:**
- Create: `Sources/CLI/Commands/WaitCommand.swift`
- Modify: `Sources/CLI/main.swift`

- [ ] **Step 1: Create WaitCommand**

```swift
import ArgumentParser
import Foundation

struct WaitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Block until a task completes; exit code mirrors the task's."
    )

    @Argument(help: "Task identifier.")
    var identifier: String

    @Option(name: .long, help: "Seconds to wait before timing out (0 = no timeout).")
    var timeout: Int = 0

    @Flag(name: .long) var json: Bool = false

    func run() async throws {
        let store = try ReadOnlyStore()
        let allTasks = try store.fetchTasks()
        let resolver = TaskResolver(items: allTasks, idOf: { $0.id }, nameOf: { $0.name })

        let task: ScheduledTask
        do {
            task = try resolver.resolve(identifier)
        } catch let err as TaskResolverError {
            FileHandle.standardError.write(Data("tasktick: \(err)\n".utf8))
            throw ExitCode(1)
        }

        // If task isn't running anymore, return its last exit code immediately.
        let runningIds = NotificationBridge.runningTaskIds(store: store)
        if !runningIds.contains(task.id) {
            let lastLog = try? store.fetchLatestLog(forTaskId: task.id)
            let code = lastLog?.exitCode ?? 0
            let dur = lastLog?.durationMs ?? 0
            printResult(name: task.name, exitCode: code, durationMs: dur, json: json)
            throw ExitCode(Int32(code))
        }

        let completedName = Notification.Name("com.lifedever.TaskTick.gui.taskCompleted")
        let center = DistributedNotificationCenter.default()
        let targetId = task.id.uuidString
        let startedAt = Date()

        let exitCode: Int32 = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            var observer: NSObjectProtocol?
            var timeoutWork: DispatchWorkItem?

            observer = center.addObserver(forName: completedName, object: nil, queue: .main) { note in
                guard let id = note.userInfo?["id"] as? String, id == targetId else { return }
                let exit = (note.userInfo?["exitCode"] as? Int) ?? 0
                if let o = observer { center.removeObserver(o) }
                timeoutWork?.cancel()
                let durMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                printResult(name: task.name, exitCode: exit, durationMs: durMs, json: json)
                cont.resume(returning: Int32(exit))
            }

            if timeout > 0 {
                let work = DispatchWorkItem {
                    if let o = observer { center.removeObserver(o) }
                    FileHandle.standardError.write(Data("tasktick: timed out after \(timeout)s\n".utf8))
                    cont.resume(throwing: ExitCode(124))
                }
                timeoutWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeout), execute: work)
            }
        }
        throw ExitCode(exitCode)
    }
}

private func printResult(name: String, exitCode: Int, durationMs: Int, json: Bool) {
    if json {
        let payload: [String: Any] = [
            "name": name,
            "exitCode": exitCode,
            "durationMs": durationMs
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    } else {
        let dur = durationMs >= 1000 ? "\(durationMs / 1000)s" : "\(durationMs)ms"
        print("✓ Completed in \(dur) (exit \(exitCode))")
    }
}
```

- [ ] **Step 2: Wire into main.swift**

Add `WaitCommand.self` to subcommands.

- [ ] **Step 3: Verify**

```bash
# Start task and immediately wait — should block until it finishes
.build/debug/tasktick run "Hello TaskTick"
.build/debug/tasktick wait "Hello TaskTick"
echo "Exit code: $?"
```
Expected: prints "Completed in Xms (exit 0)", `Exit code: 0`.

```bash
# Wait on an idle task — should return immediately with last exit code
.build/debug/tasktick wait "Hello TaskTick"
```
Expected: instant return.

```bash
# Timeout test — start a task, wait with tiny timeout
.build/debug/tasktick run "Hello TaskTick"
.build/debug/tasktick wait "Hello TaskTick" --timeout 1
echo "Exit code: $?"
```
Expected (only if Hello TaskTick takes > 1s): `tasktick: timed out after 1s`, exit code 124.

- [ ] **Step 4: Commit**

```bash
git add Sources/CLI/Commands/WaitCommand.swift Sources/CLI/main.swift
git commit -m "cli: implement wait command with --timeout

Exit code mirrors the task's; 124 on timeout (matches GNU timeout)."
```

---

## Phase 7: CLI tab completion

### Task 7.1: CompletionCommand

**Files:**
- Create: `Sources/CLI/Commands/CompletionCommand.swift`
- Modify: `Sources/CLI/main.swift`

- [ ] **Step 1: Create CompletionCommand**

```swift
import ArgumentParser
import Foundation

/// Hidden subcommand invoked by the generated zsh/bash/fish completion
/// scripts to fetch dynamic task name candidates.
struct CompletionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__complete",
        abstract: "Internal — emit task candidates for shell completion.",
        shouldDisplay: false
    )

    @Argument(help: "Prefix the user has typed so far.")
    var prefix: String = ""

    func run() throws {
        let store = try ReadOnlyStore()
        let tasks = try store.fetchTasks().filter(\.isEnabled)
        let q = prefix.lowercased()
        let candidates = tasks.filter {
            q.isEmpty || $0.name.lowercased().contains(q)
        }
        for t in candidates {
            // zsh _describe format: <value>:<description>
            let desc = t.isManualOnly ? "manual" : t.repeatType.displayName
            print("\(t.name):\(desc)")
        }
    }
}
```

- [ ] **Step 2: Wire into main.swift**

Add `CompletionCommand.self` to subcommands.

- [ ] **Step 3: Verify**

```bash
swift build
.build/debug/tasktick __complete dep
```
Expected: prints `Deploy Web:Daily` (or similar) — one line per matching task.

- [ ] **Step 4: Generate the static completion script**

swift-argument-parser generates a base script via `--generate-completion-script zsh`, but the dynamic part needs custom logic. The simplest approach is hand-rolled zsh:

Create `scripts/completion/_tasktick`:

```zsh
#compdef tasktick

_tasktick() {
    local -a subcmds
    subcmds=(
        'list:List tasks'
        'status:Show running tasks'
        'logs:Show recent execution log'
        'run:Start a task'
        'stop:Stop a running task'
        'restart:Restart a task'
        'reveal:Open task in TaskTick main window'
        'tail:Stream stdout/stderr in real time'
        'wait:Block until a task completes'
    )

    if (( CURRENT == 2 )); then
        _describe 'subcommand' subcmds
        return
    fi

    case "${words[2]}" in
        run|stop|restart|reveal|tail|wait|logs|status)
            local -a tasks
            local prefix="${words[CURRENT]}"
            local IFS=$'\n'
            tasks=($(tasktick __complete "$prefix" 2>/dev/null))
            _describe 'task' tasks
            ;;
        list)
            _arguments \
                '--filter[Filter tasks]:filter:(all manual scheduled running)' \
                '--json[Output JSON]'
            ;;
    esac
}

_tasktick
```

- [ ] **Step 5: Test the completion script locally**

```bash
mkdir -p ~/.zsh/completions
cp scripts/completion/_tasktick ~/.zsh/completions/_tasktick

# In a new zsh session:
fpath=(~/.zsh/completions $fpath)
autoload -U compinit && compinit
tasktick run <Tab>
```
Expected: Tab shows the list of task names with their schedule descriptions.

- [ ] **Step 6: Commit**

```bash
git add Sources/CLI/Commands/CompletionCommand.swift Sources/CLI/main.swift scripts/completion/
git commit -m "cli: hidden __complete subcommand + zsh completion script

Shell completion script lists subcommands statically and queries the
CLI for dynamic task candidates after a write/read command."
```

---

## Phase 8: Build / install integration

### Task 8.1: Copy CLI binary into .app bundle

**Files:**
- Modify: `scripts/build-dev.sh`
- Modify: `scripts/release.sh`

- [ ] **Step 1: Update build-dev.sh to copy the CLI binary**

In `scripts/build-dev.sh`, after the `cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${DEV_APP_NAME}"` line (around line 43), add:

```bash
# Copy CLI binary alongside the GUI binary. Same `swift build` produces both.
CLI_BIN_PATH=$(find "${BUILD_DIR}/build" -name "tasktick" -type f -perm +111 | grep -v '\.build\|\.dSYM\|\.bundle' | head -1)
if [ -n "${CLI_BIN_PATH}" ]; then
  cp "${CLI_BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/tasktick"
  echo "  CLI: ${CLI_BIN_PATH} → ${APP_BUNDLE}/Contents/MacOS/tasktick"
else
  echo "  Warning: tasktick CLI binary not found"
fi
```

- [ ] **Step 2: Update release.sh equivalently**

In `scripts/release.sh`, inside `build_arch()`, after the `cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"` line (around line 73), add:

```bash
  # Copy CLI binary
  local CLI_BIN_PATH
  CLI_BIN_PATH=$(find "${ARCH_BUILD_DIR}/build" -name "tasktick" -type f -perm +111 | grep -v '\.build\|\.dSYM\|\.bundle' | head -1)
  if [ -n "${CLI_BIN_PATH}" ]; then
    cp "${CLI_BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/tasktick"
    echo "  CLI: tasktick"
  fi
```

- [ ] **Step 3: Build dev and verify**

```bash
./scripts/build-dev.sh
ls -la "/Applications/TaskTick Dev.app/Contents/MacOS/"
```
Expected: both `TaskTick Dev` and `tasktick` listed.

```bash
"/Applications/TaskTick Dev.app/Contents/MacOS/tasktick" list
```
Expected: prints task table.

- [ ] **Step 4: Commit**

```bash
git add scripts/build-dev.sh scripts/release.sh
git commit -m "build: bundle tasktick CLI into .app/Contents/MacOS/

Dev + release builds both copy the CLI binary alongside the GUI binary
so users symlinking from /usr/local/bin will automatically pick up
upgraded CLI on every release."
```

---

## Phase 9: Settings "Enable CLI" UI

### Task 9.1: Localization strings

**Files:**
- Modify: `Sources/Localization/en.lproj/Localizable.strings`
- Modify: `Sources/Localization/zh-Hans.lproj/Localizable.strings`

- [ ] **Step 1: Add English strings**

Append to `Sources/Localization/en.lproj/Localizable.strings`:

```
"settings.cli.section.title" = "Command Line";
"settings.cli.description" = "Enable the `tasktick` command in your terminal to control TaskTick from scripts and Raycast.";
"settings.cli.enable_button" = "Enable CLI…";
"settings.cli.installed" = "Installed at %@";
"settings.cli.not_installed" = "Not installed";
"settings.cli.install.alert.title" = "Enable tasktick CLI";
"settings.cli.install.alert.message" = "Run this command in Terminal to enable the `tasktick` CLI:\n\n%@";
"settings.cli.install.alert.copy" = "Copy Command";
"settings.cli.install.alert.open_terminal" = "Open Terminal";
"settings.cli.install.alert.cancel" = "Cancel";
```

- [ ] **Step 2: Add Simplified Chinese strings**

Append to `Sources/Localization/zh-Hans.lproj/Localizable.strings`:

```
"settings.cli.section.title" = "命令行";
"settings.cli.description" = "启用 `tasktick` 命令行工具，让你在终端、脚本和 Raycast 中控制 TaskTick。";
"settings.cli.enable_button" = "启用 CLI…";
"settings.cli.installed" = "已安装于 %@";
"settings.cli.not_installed" = "未安装";
"settings.cli.install.alert.title" = "启用 tasktick CLI";
"settings.cli.install.alert.message" = "在终端中运行以下命令以启用 `tasktick`：\n\n%@";
"settings.cli.install.alert.copy" = "复制命令";
"settings.cli.install.alert.open_terminal" = "打开终端";
"settings.cli.install.alert.cancel" = "取消";
```

- [ ] **Step 3: Commit**

```bash
git add Sources/Localization/
git commit -m "i18n: strings for Settings → Command Line section"
```

### Task 9.2: CLIInstallSection view

**Files:**
- Create: `Sources/Views/Settings/CLIInstallSection.swift`
- Modify: `Sources/Views/Settings/SettingsView.swift`

- [ ] **Step 1: Create CLIInstallSection.swift**

```swift
import AppKit
import SwiftUI

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
        let cliInBundle = "/Applications/TaskTick.app/Contents/MacOS/tasktick"
        for path in candidates {
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
               target == cliInBundle {
                installState = .installed(path: path)
                return
            }
        }
        installState = .notInstalled
    }

    private func showEnableDialog() {
        // Prefer Homebrew prefix on Apple Silicon if it exists; fall back to /usr/local/bin.
        let target = FileManager.default.fileExists(atPath: "/opt/homebrew/bin")
            ? "/opt/homebrew/bin/tasktick"
            : "/usr/local/bin/tasktick"
        let cliPath = "/Applications/TaskTick.app/Contents/MacOS/tasktick"
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
```

- [ ] **Step 2: Mount CLIInstallSection in SettingsView**

Open `Sources/Views/Settings/SettingsView.swift` and find an appropriate tab (likely "General" or a new tab). Read it first:
```bash
cat Sources/Views/Settings/SettingsView.swift | head -80
```

Add a new Form section. The exact placement depends on layout — find the Form/TabView structure and add:

```swift
Form {
    // ... existing sections ...
    CLIInstallSection()
}
```

Or if there are tabs, add a new tab:

```swift
TabView {
    // ... existing tabs ...
    Form {
        CLIInstallSection()
    }
    .tabItem { Label("Command Line", systemImage: "terminal") }
}
```

The exact structure depends on what already exists. Match the existing pattern.

- [ ] **Step 3: Build dev and visually verify**

```bash
./scripts/build-dev.sh
```

Open Settings (⌘,) → check the new "Command Line" section appears with description, button, status label.

Click "Enable CLI…" → expect dialog with the sudo command. Test:
- "Copy Command" → command in clipboard
- "Open Terminal" → command in clipboard + Terminal launches
- "Cancel" → no-op

- [ ] **Step 4: Manually run the install command and verify state updates**

```bash
sudo ln -sf "/Applications/TaskTick Dev.app/Contents/MacOS/tasktick" /usr/local/bin/tasktick-dev
# Then re-open Settings → status should still say "Not installed" because we used a different name on purpose.
# Now real install:
sudo ln -sf "/Applications/TaskTick.app/Contents/MacOS/tasktick" /usr/local/bin/tasktick
# Reopen Settings → status now says "Installed at /usr/local/bin/tasktick"
```

- [ ] **Step 5: Commit**

```bash
git add Sources/Views/Settings/CLIInstallSection.swift Sources/Views/Settings/SettingsView.swift
git commit -m "settings: Command Line section with enable + install state

NSAlert dialog shows the sudo command pre-filled with copy + open
Terminal helpers (1Password 7 pattern). State detection compares the
existing symlink target against /Applications/TaskTick.app's CLI."
```

---

## Phase 10: Homebrew Cask + ship

### Task 10.1: Update Homebrew Cask

**Files:**
- Modify: `../homebrew-tap/Casks/task-tick.rb`

- [ ] **Step 1: Edit the cask**

Read the current cask:
```bash
cat ../homebrew-tap/Casks/task-tick.rb
```

Add a `binary` line after the `app` line. Final shape should look like:

```ruby
cask "task-tick" do
  version "x.y.z"
  sha256 "..."

  url "..."
  name "TaskTick"
  desc "..."
  homepage "..."

  app "TaskTick.app"
  binary "#{appdir}/TaskTick.app/Contents/MacOS/tasktick"

  # ... rest of the cask
end
```

`appdir` is a built-in cask helper that resolves to `/Applications` (or whatever `--appdir` was set to).

- [ ] **Step 2: Smoke-test by reinstalling locally**

```bash
brew uninstall --cask task-tick 2>/dev/null
brew install --cask ./../homebrew-tap/Casks/task-tick.rb
which tasktick
tasktick --version
```
Expected: `tasktick` resolves to `$(brew --prefix)/bin/tasktick`, prints version.

- [ ] **Step 3: Commit cask update**

```bash
cd ../homebrew-tap
git add Casks/task-tick.rb
git commit -m "task-tick: install tasktick CLI alongside the .app"
```

### Task 10.2: Ship via /release

**Files:** none — invokes the release skill.

- [ ] **Step 1: Run the full release pipeline**

This step is run from the user's prompt:
```
/release 1.8.0
```

This goes through the existing release skill's preflight checklist (uncommitted changes, semver bump, swift test, build dual-arch, DMG, GitHub Release, Homebrew Cask version + sha256 update + commit + push).

Preflight in particular: check the spec's `swift-ship-check` skill triggers (per CLAUDE.md):
- SPM resource bundle still copied at `.app` root
- SwiftData store path unchanged
- Fresh-install path tested
- **NEW**: `tasktick` binary present in `.app/Contents/MacOS/`
- **NEW**: `tasktick:// ` URL Scheme registered in Info.plist
- Localizations EN + zh-Hans both have new keys

Pre-release manual smoke (tested OFF the local build cache, on a freshly-installed DMG):
- Install fresh DMG
- Open Settings → Command Line → click Enable → run sudo command → verify "Installed"
- `tasktick list` works
- `tasktick run "Hello TaskTick"` triggers task in GUI
- Quit GUI → `tasktick run "Hello TaskTick"` re-launches GUI and runs task
- `tasktick tail "Hello TaskTick"` while task runs (in another terminal)

- [ ] **Step 2: Update README**

Add a "CLI" section to `README.md` (and `README_zh.md`) introducing the CLI:

```markdown
## Command Line

TaskTick ships with a `tasktick` CLI that mirrors the in-app Quick Launcher.
Brew users get it automatically. DMG users can enable it from
**Settings → Command Line**.

```sh
tasktick list                     # list tasks
tasktick run "Deploy Web"         # start a task
tasktick stop "Deploy Web"        # stop a running task
tasktick wait "Deploy Web"        # block until it finishes
tasktick logs "Deploy Web"        # view last execution output
tasktick tail "Deploy Web"        # follow a running task's output
```

Tab completion is available — see `tasktick --help`.
```

- [ ] **Step 3: Commit README updates**

```bash
git add README.md README_zh.md
git commit -m "docs: add Command Line section to README

Brief intro to the tasktick CLI bundled with v1.8.0+. Full reference
lives in tasktick --help."
```

---

## Self-Review Checklist

Run before declaring done:

- [ ] **Spec coverage**: All 9 commands implemented (list, status, logs, run, stop, restart, reveal, tail, wait) — Phases 4-6 ✓
- [ ] **Spec coverage**: URL Scheme registered in Info.plist — Phase 1 ✓
- [ ] **Spec coverage**: Distributed Notification names match spec §6.1 verbatim — see CLIBridge.swift constants ✓
- [ ] **Spec coverage**: JSON schema in §5.4 implemented in TaskDTO — Phase 3 ✓
- [ ] **Spec coverage**: Identifier resolution per §5.2 (UUID/prefix/name/fuzzy) — Phase 3 TaskResolver ✓
- [ ] **Spec coverage**: Exit codes per §5.5 (0/1/2/124/130/≥3) — verified across commands ✓
- [ ] **Spec coverage**: Settings "Enable CLI" button — Phase 9 ✓
- [ ] **Spec coverage**: Tab completion — Phase 7 ✓
- [ ] **Spec coverage**: Homebrew Cask binary — Phase 10 ✓
- [ ] **No placeholders**: every code step has complete code, no "TBD"
- [ ] **Type consistency**: TaskDTO field names match across factory, JSON, tests, Raycast contract
- [ ] **Build green at every commit**: each phase ends in a committable checkpoint
- [ ] **Manual test pass**: full smoke checklist in Phase 10 Task 10.2 Step 1

## Out of Scope (Plan B — separate plan after this lands)

- Raycast extension scaffold + commands (`tasktick-raycast` independent repo)
- Raycast Store submission
- Linking against the CLI from external scripts in production user environments

These wait until the CLI has been live for a release cycle and feedback has surfaced any contract changes.
