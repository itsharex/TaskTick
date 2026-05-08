# Raycast Extension + tasktick CLI 设计

**日期**: 2026-05-08
**状态**: Draft (待 review)
**作者**: lifedever

## 1. 目标

把 TaskTick 的 Quick Launcher 体验搬到 Raycast，让用户在 Raycast 里能：
- 模糊搜索任务并 Enter 运行 / 停止
- ⌘R 重启、⌘O 在主窗口定位
- 查看任务运行状态、最近日志、实时输出

实现路径：在 TaskTick 主仓库内新增一个独立的 `tasktick` CLI，Raycast 扩展通过 shell out 调 CLI。这条路线对标 1Password 的 `op` CLI，行业事实标杆。

## 2. Non-Goals

明确**不做**的事项，避免范围蔓延：

- CLI 不提供 add/edit/delete 任务能力（编辑走 GUI；CLI 写 SwiftData 复杂度高 + schema 演进负担大）
- CLI 不提供 import-cron / export（GUI 已有）
- CLI 不做 daemon 化（TaskTick.app 本身就是常驻菜单栏的 daemon）
- v1 不做 fzf-style TUI 交互选择器（用户可以 `tasktick run "$(tasktick list --json | jq -r '.[].name' | fzf)"` 自组合）
- Raycast 端不直接读 SwiftData store 也不直接发 URL Scheme，全部走 CLI（保留单一接口收敛点）

## 3. 架构

```
┌───────────────────────────────┐    Distributed Notification     ┌────────────────────┐
│  TaskTick.app (GUI, daemon)   │ ◄────────────────────────────── │ tasktick CLI       │
│  • TaskScheduler              │                                  │ (.app/Contents/    │
│  • ScriptExecutor             │ ──────► tasktick:// URL Scheme   │   MacOS/tasktick)  │
│  • SwiftData store (writer)   │      (fallback: 唤起 GUI)         │ • read SwiftData   │
│  • URL Scheme handler         │                                  │   (read-only)      │
│  • DistributedNotification    │ ◄──── shared Sources/Kit/        │ • dispatch via     │
│    listener                   │       (源码层共享)                 │   DistributedNotif │
└───────────────────────────────┘                                  └────────────────────┘
                                                                            ▲
                                                                            │ execa
                                                                            │
                                                              ┌─────────────────────────┐
                                                              │ tasktick-raycast        │
                                                              │ (独立 repo, npm)         │
                                                              │ • Search Tasks (List)   │
                                                              │ • Run / Stop / Restart  │
                                                              │ • Reveal / Logs         │
                                                              └─────────────────────────┘
```

**职责边界**：

| 组件 | 职责 | 不做 |
|---|---|---|
| TaskTick.app (GUI) | SwiftData 唯一 writer；执行所有脚本进程；维护 running 状态；广播任务事件 | 不暴露 API（只接收 Notification 和 URL Scheme） |
| `tasktick` CLI | 读 SwiftData（list/status/logs）；分派写命令到 GUI；订阅事件流（tail/wait）| 不直接执行脚本；不直接写数据库 |
| Raycast 扩展 | UI 层，shell out 到 CLI | 不绕过 CLI 直接访问数据 |

## 4. 用户故事

| Story | 命令路径 |
|---|---|
| Raycast 里搜任务、Enter 运行 | Raycast → `tasktick run <id>` → CLI 检测 GUI → Distributed Notification 或 URL Scheme 唤起 → GUI 的 ScriptExecutor 执行 |
| 用户脚本里串 TaskTick 任务做 chain | `tasktick run "deploy" && tasktick wait "deploy" && tasktick run "notify"` |
| 终端里查任务 | `tasktick list` 表格 / `tasktick list --json \| jq` |
| 终端里跟着任务输出看 | `tasktick tail "build"` 流式输出，Ctrl+C 退出 |
| Raycast 里查最近一次输出 | Raycast 的 Action "View Last Output" → `tasktick logs <id> --json` |

## 5. CLI 接口契约

### 5.1 全局选项

- `--json` — 切换到结构化输出（默认人类可读表格 / 行）
- `--help` / `-h` — 子命令帮助
- `--version` / `-v` — 版本号

### 5.2 Identifier 解析

所有接受 `<id>` 的命令统一规则：

1. UUID 全匹配
2. UUID 前缀匹配（≥4 位）
3. Name 完全匹配（大小写不敏感）
4. Name fuzzy match（复用 GUI 的 `Engine/FuzzyMatch.swift`）

匹配多个 → exit 1，stderr 列出候选要求精确化。

### 5.3 命令清单

| 命令 | 类别 | 主要参数 | stdout 默认 | `--json` 输出 | exit 码 |
|---|---|---|---|---|---|
| `list` | Read | `--filter all\|manual\|scheduled\|running` | 表格 | `Task[]` | 0 |
| `status` | Read | `[<id>]` 可选 | 单任务行 / 全局摘要 | `StatusGlobal` 或 `StatusTask` | 0 |
| `logs` | Read | `<id>` `--lines N` `--exec <execId>` | 时间戳行流 | `ExecutionLog` 对象 | 0 / 1（无日志） |
| `run` | Write | `<id>` | `✓ Started: <name>` | `{id, status:"started"}` | 0 |
| `stop` | Write | `<id>` | `✓ Stopped: <name>` | `{id, status:"stopped"}` | 0 |
| `restart` | Write | `<id>` | `✓ Restarted: <name>` | `{id, status:"restarted"}` | 0 |
| `reveal` | Write | `<id>` | `✓ Revealed in TaskTick: <name>` | `{id, status:"revealed"}` | 0 |
| `tail` | Stream | `<id>` | 实时 stdout/stderr 行流 | NDJSON 一行一条 | 0 / 130（Ctrl+C） |
| `wait` | Stream | `<id>` `--timeout N` | `✓ Completed in <Xs> (exit <N>)` | `{id, exitCode, durationMs}` | **透传任务的 exit code**，超时 124 |

### 5.4 JSON Schema

```jsonc
// Task (list / status 共用)
{
  "id": "a3f9c200-...",
  "shortId": "a3f9",
  "name": "Deploy Web",
  "kind": "scheduled",          // "scheduled" | "manual"
  "enabled": true,
  "status": "idle",             // "idle" | "running"
  "scheduleSummary": "Daily at 09:00",
  "lastRunAt": "2026-05-08T14:32:01Z",
  "lastRunDurationSec": 47,
  "lastExitCode": 0,
  "createdAt": "2026-04-01T10:00:00Z"
}

// StatusGlobal
{
  "running": [
    { "id": "...", "name": "Backup Photos", "startedAt": "...", "elapsedSec": 12 }
  ],
  "totalEnabled": 14,
  "totalRunning": 1
}

// ExecutionLog (logs --json)
{
  "executionId": "...",
  "taskId": "...",
  "startedAt": "...",
  "endedAt": "...",
  "exitCode": 0,
  "stdout": "...",
  "stderr": "...",
  "lines": [{ "ts": "...", "stream": "stdout", "text": "..." }]
}
```

### 5.5 退出码约定

- `0` — 成功 / 任务正常结束
- `1` — 通用错误（任务没找到、参数错、唤起 GUI 失败、SwiftData 锁定）
- `2` — 用法错误（参数缺失等，由 swift-argument-parser 自动产生）
- `124` — `wait --timeout` 超时（匹配 GNU `timeout`）
- `130` — Ctrl+C 中断（匹配 unix 约定）
- `≥3` — `wait` 时透传任务的 exit code

### 5.6 错误处理

| 场景 | exit | stderr |
|---|---|---|
| Task identifier 没匹配 | 1 | `tasktick: no task matches "depl"` |
| Identifier 多个候选 | 1 | `multiple matches:\n  a3f9 Deploy Web\n  b1c4 Deploy Mobile\nbe more specific.` |
| `run` 一个已经 running 的任务 | 0 | stderr `note: already running` (no-op，幂等) |
| `stop` 一个 idle 任务 | 0 | stderr `note: not running` (no-op) |
| `tail` 一个 idle 任务 | 1 | `tasktick: <name> is not running` |
| `wait` 一个 idle 任务（已结束） | 透传 lastExitCode | （无） |
| GUI 唤起 10s 超时 | 1 | `tasktick: TaskTick.app failed to launch within 10s` |
| SwiftData store 锁定 | 1 | `tasktick: cannot read database (TaskTick may be migrating)` |

**幂等性原则**：run/stop 是 no-op-friendly。脚本里 `tasktick run X` 不需要先查状态。

## 6. 通信机制

### 6.1 Distributed Notification

CLI 进程和 GUI 进程之间走 `DistributedNotificationCenter`（macOS 原生 IPC，零依赖、低延迟）。

| 方向 | 名字 | Payload |
|---|---|---|
| CLI → GUI | `com.lifedever.TaskTick.cli.run` | `{"id": "<uuid>"}` |
| CLI → GUI | `com.lifedever.TaskTick.cli.stop` | `{"id": "<uuid>"}` |
| CLI → GUI | `com.lifedever.TaskTick.cli.restart` | `{"id": "<uuid>"}` |
| CLI → GUI | `com.lifedever.TaskTick.cli.reveal` | `{"id": "<uuid>"}` |
| GUI → CLI (broadcast) | `com.lifedever.TaskTick.gui.taskStarted` | `{"id", "executionId", "startedAt"}` |
| GUI → CLI (broadcast) | `com.lifedever.TaskTick.gui.taskCompleted` | `{"id", "executionId", "exitCode", "endedAt"}` |
| GUI → CLI (broadcast) | `com.lifedever.TaskTick.gui.logChunk` | `{"id", "executionId", "stream", "text"}` |

`DistributedNotificationCenter.default().postNotificationName(_:object:userInfo:deliverImmediately:)` —— 一行调用。

### 6.2 URL Scheme（GUI 没跑时唤起）

Info.plist 注册 `tasktick://`：

| URL | 等价 Notification |
|---|---|
| `tasktick://run?id=<uuid>` | `cli.run` |
| `tasktick://stop?id=<uuid>` | `cli.stop` |
| `tasktick://restart?id=<uuid>` | `cli.restart` |
| `tasktick://reveal?id=<uuid>` | `cli.reveal` |

`AppDelegate.application(_:open:)` 接收 URL → 路由到同一个 `CLIBridge.handle(action:id:)` 函数（DistributedNotification handler 也走这个函数，避免双入口分叉）。

### 6.3 写命令的执行流程

以 `run` 为例：

```
1. CLI 解析 identifier → UUID
2. 检查 GUI: NSRunningApplication.runningApplications(withBundleIdentifier:)
3a. GUI 在跑 → DistributedNotificationCenter.default.postNotificationName(.cli.run, ...)
              → exit 0
3b. GUI 没跑 → NSWorkspace.shared.open(URL("tasktick://run?id=<uuid>"))
              → 轮询 NSRunningApplication 直到 GUI 完成 launch (max 10s)
              → exit 0
              → 失败 → exit 1, stderr 报错
```

### 6.4 Stream 命令实现

- **tail**: 启动时检查任务是否 running（不在跑就 exit 1）；订阅 `gui.logChunk` 过滤当前 task id；订阅 `gui.taskCompleted` 终态时 exit 0
- **wait**: 启动时检查任务最近一次执行；如果已结束，立即用 `lastExitCode` 退出；否则订阅 `gui.taskCompleted`，超时按 `--timeout` flag 走 124

## 7. TaskTick.app 端实现要点

### 7.1 Package.swift 改动

新增 CLI executable target，复用源码层共享文件（不抽 library，避免大重构）：

```swift
// 新增依赖
dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
]

// 新增 CLI target
.executableTarget(
    name: "tasktick",
    dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser")
    ],
    path: "Sources",
    exclude: ["App", "Views", "Localization", "Resources"],
    sources: [
        "CLI",
        "Models",
        "Engine/FuzzyMatch.swift",
        "Engine/StoreMigration.swift",
        "Engine/StoreHardener.swift"
    ]
)
```

`sources:` 显式列出 CLI 用得上的共享文件 —— `Models/`（ScheduledTask、ExecutionLog）、`Engine/FuzzyMatch.swift`、`Engine/StoreMigration.swift`（解析 store URL）、`Engine/StoreHardener.swift`（read-only 打开前先 checkpoint WAL）。其他 Engine 文件（TaskScheduler、ScriptExecutor 等 @MainActor 单例）CLI 不需要也不能链接（会引入 SwiftUI 依赖）。

### 7.2 新增 GUI 端模块

| 文件 | 职责 |
|---|---|
| `Sources/Engine/CLIBridge.swift` | URL Scheme + DistributedNotification 接收入口；handle(action:id:) 路由到 ScriptExecutor / Scheduler / MainWindowSelection |
| `Sources/Engine/CLIBroadcaster.swift` | 监听 ScriptExecutor 的 task started/completed/log chunk 事件，转发为 DistributedNotification |
| `Sources/Views/Settings/CLIInstallSection.swift` | Settings 里的"启用 CLI"按钮，弹 NSAlert 展示 sudo 命令 |

### 7.3 Info.plist 改动

`Sources/App/Info.plist`（如不存在则在 Package.swift 里通过 `.copy` 配置）增加：

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

### 7.4 Settings "启用 CLI" 按钮

UI（参考 1Password 7 的做法）：

```
┌─ Command Line ─────────────────────────────────────┐
│                                                     │
│  Enable the `tasktick` command in your terminal     │
│  to control TaskTick from scripts and Raycast.      │
│                                                     │
│  [ Enable CLI... ]                                  │
│                                                     │
│  ✓ Currently installed at /usr/local/bin/tasktick   │
│                                                     │
└─────────────────────────────────────────────────────┘
```

按钮点击 → NSAlert：
```
Run this command in Terminal to enable the `tasktick` CLI:

  sudo ln -sf "/Applications/TaskTick.app/Contents/MacOS/tasktick" \
              /usr/local/bin/tasktick

[ Copy Command ]  [ Open Terminal ]  [ Cancel ]
```

按 [ Copy Command ] 写入剪贴板；[ Open Terminal ] 调 `NSWorkspace.open` 启动 Terminal。

**安装状态检测**：每次 Settings 打开时 stat `/usr/local/bin/tasktick`，符号链接指向当前 `.app` → 显示 "Installed"，否则 "Not installed"。

**Apple Silicon 路径优先级**：检查 `/opt/homebrew/bin` 是否在 PATH 里，若是优先建议装到 `/opt/homebrew/bin/tasktick`，否则 fallback 到 `/usr/local/bin/tasktick`。

### 7.5 与 build-dev.sh / release.sh 的集成

CLI 二进制是 `.executableTarget`，`swift build` 会自动产出。脚本只需要把 `tasktick` 二进制 cp 到 `.app/Contents/MacOS/`，和 GUI 主二进制并列。

## 8. tasktick CLI 端实现要点

### 8.1 项目结构

```
Sources/CLI/
├── main.swift                  # @main + AsyncParsableCommand 根命令
├── Commands/
│   ├── ListCommand.swift
│   ├── StatusCommand.swift
│   ├── RunCommand.swift
│   ├── StopCommand.swift
│   ├── RestartCommand.swift
│   ├── RevealCommand.swift
│   ├── LogsCommand.swift
│   ├── TailCommand.swift
│   ├── WaitCommand.swift
│   └── CompletionCommand.swift  # __complete 内部命令，给 zsh 补全脚本调
├── Bridge/
│   ├── ReadOnlyStore.swift      # 只读 ModelContainer 包装
│   ├── GUILauncher.swift        # 检测 + 唤起 + 等待 GUI
│   └── NotificationBridge.swift # DistributedNotification 收发
├── Output/
│   ├── TableRenderer.swift      # 默认表格输出
│   └── JSONEncoder+Default.swift
└── Identifier/
    └── TaskResolver.swift       # UUID/prefix/name/fuzzy 多级解析
```

### 8.2 ReadOnlyStore 设计

CLI 进程独立 open 一份 read-only `ModelContainer`，存储路径用 `StoreMigration.resolveStoreURL()`（和 GUI 一致）：

```swift
// 简化伪代码
let storeURL = StoreMigration.resolveStoreURL()
StoreHardener.hardenStore(at: storeURL)  // checkpoint WAL into main store
let config = ModelConfiguration(
    schema: Schema([ScheduledTask.self, ExecutionLog.self]),
    url: storeURL,
    allowsSave: false  // ← 关键：CLI 永不写
)
let container = try ModelContainer(for: schema, configurations: [config])
```

`allowsSave: false` 确保 CLI 进程哪怕逻辑出错也不会污染 store。

### 8.3 Tab 补全脚本生成

swift-argument-parser 提供 `--generate-completion-script zsh|bash|fish`，但默认只支持静态值。动态任务列表通过自定义 completion handler 实现：

```swift
@Argument(completion: .custom { _ in
    // 这里 swift-argument-parser 会调 `tasktick __complete <prefix>`
    // 实际逻辑在 CompletionCommand 里
})
var taskId: String
```

`tasktick __complete` 是一个隐藏子命令，输出 `name\tdescription` 一行一条，zsh 补全脚本 `_describe` 这些值。

**安装路径**：
- Homebrew 用户: cask 自动 link 到 `$(brew --prefix)/share/zsh/site-functions/_tasktick`
- DMG 用户: Settings 弹窗里多一行 `tasktick --generate-completion-script zsh > ~/.zsh/completions/_tasktick`

## 9. tasktick-raycast 扩展

### 9.1 仓库

新建独立 GitHub repo `lifedever/tasktick-raycast`（结构对齐 fnm-raycast）：

```
tasktick-raycast/
├── package.json
├── src/
│   ├── search-tasks.tsx         # 主命令：List + 模糊搜索 + ActionPanel
│   ├── tasktick.ts              # CLI shell out 封装
│   └── types.ts                 # Task / Status / ExecutionLog 类型对齐 5.4 schema
├── assets/
│   └── command-icon.png
├── README.md
└── tsconfig.json
```

### 9.2 命令清单（package.json）

v1 提供单一命令 `Search Tasks`（mode: view），点开是 List：

```jsonc
{
    "name": "tasktick",
    "title": "TaskTick",
    "description": "Quick launcher for TaskTick scheduled tasks",
    "icon": "command-icon.png",
    "categories": ["Productivity"],
    "preferences": [
        {
            "name": "cliPath",
            "type": "textfield",
            "required": false,
            "title": "CLI Path",
            "description": "Custom path to `tasktick` (auto-detected if empty)",
            "placeholder": "/usr/local/bin/tasktick"
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
}
```

### 9.3 主视图（search-tasks.tsx）

- `useExec("tasktick", ["list", "--json"])` 拿任务数组（带 keepPreviousData，1s 间隔 revalidate 拿 running 状态）
- `<List searchBarPlaceholder="Search tasks…" />`
- 每个 `<List.Item>` 显示：图标（manual / scheduled / running 三态）+ 名字 + status accessory
- `<ActionPanel>` 按 QuickLauncher 对齐：
    - **Run** (Enter) — `await execa("tasktick", ["run", task.id])`
    - **Stop** (Enter when running)
    - **Restart** (⌘R) — `tasktick restart <id>`
    - **Reveal in TaskTick** (⌘O) — `tasktick reveal <id>`
    - **View Last Output** (⌘L) — push 一个新 view 显示 `tasktick logs <id> --json` 结果
    - **Copy Task ID** (⌘C)

### 9.4 CLI 自动检测

`tasktick.ts` 启动时按顺序找 CLI：

1. Preference 里设的 `cliPath`
2. `/usr/local/bin/tasktick`
3. `/opt/homebrew/bin/tasktick`
4. `/Applications/TaskTick.app/Contents/MacOS/tasktick`

都找不到 → 显示一个 `<Detail>` 视图，说明"先在 TaskTick > Settings > Command Line 启用 CLI"。

### 9.5 错误处理

CLI 进程的非 0 退出 → Raycast `<Toast>` 显示 stderr 第一行（友好提示）。

## 10. 安装与分发

### 10.1 TaskTick app 升级

- `release.sh` 会自动打包 CLI 二进制（`swift build` 副产物）到 `.app/Contents/MacOS/tasktick`
- DMG 用户：升级后 CLI 自动跟着更新（symlink 指向 `.app` 内的二进制，`.app` 整体替换即可）
- 旧版用户首次启动新版会看到 Settings 里的 "Enable CLI" 按钮，引导启用

### 10.2 Homebrew Cask 改动

`homebrew-tap/Casks/task-tick.rb` 加 `binary` 字段：

```ruby
cask "task-tick" do
    # ... 原有内容 ...
    app "TaskTick.app"
    binary "#{appdir}/TaskTick.app/Contents/MacOS/tasktick"
end
```

brew 用户 `brew install --cask task-tick` 会自动 symlink CLI 到 `$(brew --prefix)/bin/tasktick`，**不需要 sudo、零操作**。

### 10.3 Raycast 扩展发布

提交 PR 到 `raycast/extensions` monorepo，按 Raycast Store 规范准备：
- README 双语（英文为主，中文补充）
- 4 张 Screenshot
- 256x256 命令图标（绿色时钟 badge）
- contributors 列入 lifedever

Review 周期通常几天到一周。

## 11. 测试策略

### 11.1 TaskTick.app

- `Sources/CLI/Bridge/ReadOnlyStore.swift` 单测：read-only ModelContainer 拒绝写入
- `CLIBridge.handle` 单测：mock URL / Notification 各种 payload，验证路由到正确的 ScriptExecutor / Scheduler 调用
- `CLIBroadcaster` 单测：mock task event → 验证发出对应 Distributed Notification

### 11.2 tasktick CLI

- 每个命令的端到端测试，使用 fixture SwiftData store
- TaskResolver 单测：UUID/prefix/name/fuzzy 各种边界
- 通信集成测试：spawn 一个 mock GUI（监听 Distributed Notification），断言 `tasktick run X` 正确发出

### 11.3 手测清单（Pre-release）

参考 CLAUDE.md 的"发版前全新安装测试"流程：
- 完全卸载 → DMG 重装
- 启用 CLI（按钮 + sudo 命令）
- `tasktick list` 输出非空
- `tasktick run "Hello TaskTick"` GUI 主窗口、菜单栏、Toast 同步反应
- 手动 `Cmd+Q` 退 GUI → `tasktick run X` 自动唤起 GUI 并执行
- Raycast 装扩展 → 搜任务 Enter → 同上验证

## 12. Backlog (v2+)

- TUI 交互式 fzf-like 选择器（`tasktick run` 不带参数时进入）
- `tasktick add/edit/delete` —— 等用户呼声
- `tasktick export --format=mac-shortcut` 导出为 macOS Shortcut 自动化
- Raycast 扩展加 `Create Task` 命令（mode: form）
- AppleScript dictionary（如果用户有 Shortcuts.app / Alfred 集成需求）

## 13. 风险与缓解

| 风险 | 缓解 |
|---|---|
| Distributed Notification 在受限 Sandbox 下被 macOS 拦截 | TaskTick 当前未启用 App Sandbox，无影响。未来若启用需要 entitlement `com.apple.security.application-groups` 共享前缀 |
| sudo symlink 命令对纯 GUI 用户不友好 | NSAlert 文案配大号字体 + 一键 Copy；Homebrew 用户全自动；不再阻塞 |
| swift-argument-parser 动态补全脚本 zsh 行为有差异 | 参考 `op completion zsh` / `gh completion zsh` 已有实现 |
| CLI 二进制增加 `.app` 体积 | 一个 ArgumentParser CLI 通常 5-10MB，整个 .app 当前约 30MB，可接受 |
| SwiftData schema 演进 break CLI | CLI 共享 `Sources/Models/` 源码，schema 改动会同步 break CLI 编译 → 在编译期暴露 |
