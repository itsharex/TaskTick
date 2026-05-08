# Raycast Extension 实施 Spec（§9 增量）

**日期**: 2026-05-08
**状态**: Approved (brainstorm done)
**作者**: lifedever
**基线**: `2026-05-08-raycast-extension-design.md` §9
**新仓库**: `~/Documents/Dev/myspace/tasktick-raycast/` → GitHub `lifedever/tasktick-raycast`

---

## 1. 背景

§9 已经把 Raycast 扩展整体形态定下：单 Search Tasks 命令、shell out 到 `tasktick` CLI、List + ActionPanel。CLI 已实现、merge 到 main、未发版。这份 spec 解决 §9 留白的几个细节：

| 留白 | 决议 |
|---|---|
| 开发期 CLI 二进制怎么用（未发版） | 用 `tasktick-dev`，扩展通过 `cliPath` preference 手动覆盖 |
| 怎么跟 running 状态（§9.3 1s 轮询代价不可接受） | 新增 `tasktick events` 子命令，扩展 spawn 长连接子进程，事件驱动更新 |
| 写命令是否反馈 toast | TaskTick.app 端新增 `ActionToast` helper：run/stop/restart 成功 + 失败都发系统通知；reveal 不发；GUI 按钮也走同一入口 |
| 发布路径 | 先本地 ray develop 调，再提 Raycast Store PR |
| Preferences 范围 | `cliPath`、`showCompletionToast`、`logsFormat (text\|json)` |
| UI 语言 | 仅英文 |

---

## 2. TaskTick.app 端改动

### 2.1 新增 `Sources/Engine/ActionToast.swift`

**目的**：统一"用户主动触发的写操作"的反馈通知入口。所有 run/stop/restart 路径（CLI 来的 / GUI Run/Stop 按钮 / 菜单栏 / QuickLauncher）最后一行调它。

```swift
@MainActor
enum ActionToast {
    case started(taskName: String)
    case stopped(taskName: String)
    case restarted(taskName: String)
    case failed(taskName: String?, reason: String)

    static func notify(_ event: ActionToast) {
        // 走 NotificationManager.shared.send(title:body:)
        // title 走 L10n.tr("toast.action.started/stopped/restarted/failed")
        // body 是任务名 + 可选 reason
    }
}
```

**和现有 `ScriptExecutor.notifyOnSuccess/notifyOnFailure` 的关系**：
- ScriptExecutor 现有通知：脚本**完成时**（success/failure），按 task 维度的开关控制
- ActionToast：用户**触发动作时**（run/stop/restart 的瞬间），按全局开关 `notificationsEnabled` 控制
- 两者互不替代。run 一个长任务的话，先看到 ActionToast.started → 几分钟后看到 ScriptExecutor 的 success/failure 完成通知

### 2.2 ActionToast 接入点

| 入口 | 现有调用 | 加一行 |
|---|---|---|
| `CLIBridge.handleRun(id:)` | 调 `TaskScheduler.runManually(...)` | `ActionToast.notify(.started(taskName: t.name))` |
| `CLIBridge.handleStop(id:)` | 调 `ScriptExecutor.stop(...)` | `ActionToast.notify(.stopped(taskName: t.name))` |
| `CLIBridge.handleRestart(id:)` | stop + run | `ActionToast.notify(.restarted(taskName: t.name))` |
| `CLIBridge.handleReveal(id:)` | 主窗口 + 选中 | （不发） |
| GUI 主窗口 Run 按钮 | 现有 onTap | `ActionToast.notify(.started(...))` |
| GUI 主窗口 Stop 按钮 | 现有 onTap | `ActionToast.notify(.stopped(...))` |
| 菜单栏 QuickLauncher Enter | 现有 | `ActionToast.notify(.started(...))` |
| CLIBridge 写命令解析失败（任务找不到等） | 之前可能 silent | `ActionToast.notify(.failed(taskName: nil, reason: "..."))` |

### 2.3 新增 `Sources/Engine/CLIBroadcaster.swift` （已在 §7.2 列出）

确认：`taskStarted` / `taskCompleted` 这两个 broadcast 是 §9 设计已有的、本 spec 不增不减。`logChunk` 也保留（`tail` 用），但**不进入 `events` 流**。

### 2.4 新增 `Sources/CLI/Commands/EventsCommand.swift`

```
USAGE: tasktick events
PURPOSE: 长连接订阅 GUI 事件，stdout 流式输出 NDJSON。Raycast 扩展用这个替代轮询。
```

输出格式（一行一个事件）：
```jsonc
{"type":"started",   "id":"<uuid>", "executionId":"<uuid>", "ts":"2026-05-08T10:00:00Z"}
{"type":"completed", "id":"<uuid>", "executionId":"<uuid>", "exitCode":0, "ts":"2026-05-08T10:00:47Z"}
```

行为：
- 启动后**不**做初始 dump（初始状态由 `list --json` 提供）
- 订阅 `gui.taskStarted`、`gui.taskCompleted`
- **不**包含 `logChunk`（流量大，留给 `tail` 子命令）
- SIGINT → exit 130；SIGTERM → exit 0
- stdout 写入失败（pipe broken，扩展退出了）→ 干净退出 0

GUI 不在跑时也照常订阅（Distributed Notification Center 不需要 publisher 在线），就是没事件出。

### 2.5 Localization 增量

`Sources/Localization/{en,zh-Hans}.lproj/Localizable.strings` 增：

```
"toast.action.started"   = "Started: %@";  / "已启动：%@"
"toast.action.stopped"   = "Stopped: %@";  / "已停止：%@"
"toast.action.restarted" = "Restarted: %@";/ "已重启：%@"
"toast.action.failed"    = "Action failed: %@"; / "操作失败：%@"
```

---

## 3. tasktick-raycast 扩展

### 3.1 仓库脚手架

**初始化方式**：用 Raycast 官方脚手架 `npx create-raycast-extension`，模板选 "View Command"。生成在 `~/Documents/Dev/myspace/tasktick-raycast/`。理由：模板默认带 ESLint/Prettier/Raycast schema，少踩坑。

**初始化后清理**：删除模板带的 README boilerplate，重写为 TaskTick 专用。

### 3.2 项目结构

```
tasktick-raycast/
├── package.json
├── tsconfig.json
├── eslint.config.mjs              # raycast preset
├── .gitignore                     # node_modules, .raycast
├── README.md                      # 英文，Store-grade
├── CHANGELOG.md
├── assets/
│   ├── command-icon.png           # 256x256 + @dark + @2x
│   └── extension-icon.png
├── metadata/                      # Store screenshots（占位）
└── src/
    ├── search-tasks.tsx           # 主命令
    ├── lib/
    │   ├── tasktick.ts            # CLI shell out 封装（list/run/stop/restart/reveal/logs）
    │   ├── events.ts              # tasktick events 子进程管理 + EventEmitter
    │   ├── cli-detection.ts       # cliPath 自动探测
    │   ├── types.ts               # Task / ExecutionLog 类型对齐 §5.4
    │   └── format.ts              # 时间戳 / 状态 icon / 友好错误文案
    └── views/
        ├── tasks-list.tsx         # 主 List 组件，由 search-tasks 渲染
        ├── logs-detail.tsx        # View Last Output detail
        └── cli-not-found.tsx      # CLI 没装时的引导 detail
```

### 3.3 package.json 关键字段

```jsonc
{
    "name": "tasktick",
    "title": "TaskTick",
    "description": "Quick launcher for TaskTick scheduled tasks",
    "icon": "extension-icon.png",
    "author": "lifedever",
    "categories": ["Productivity", "Developer Tools"],
    "license": "MIT",
    "preferences": [
        {
            "name": "cliPath",
            "type": "textfield",
            "required": false,
            "title": "CLI Path",
            "description": "Path to tasktick (auto-detected if empty). For dev, use /Applications/TaskTick Dev.app/Contents/MacOS/tasktick-dev.",
            "placeholder": "/usr/local/bin/tasktick"
        },
        {
            "name": "showCompletionToast",
            "type": "checkbox",
            "required": false,
            "title": "Show in-Raycast toast",
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
}
```

### 3.4 主视图（search-tasks.tsx → tasks-list.tsx）

**初始加载**：
```ts
const { data: tasks, isLoading, revalidate } = useExec(cliPath, ["list", "--json"], {
    keepPreviousData: true,
    parseOutput: (out) => JSON.parse(out.stdout) as Task[],
});
```

**事件订阅**（替代 §9.3 的 1s 轮询）：
```ts
useEffect(() => {
    const events = startEventsStream(cliPath);
    events.on("started", ({ id }) => mutateTaskRunning(id, true));
    events.on("completed", ({ id }) => mutateTaskRunning(id, false));
    events.on("error", () => /* 失败重连，5s 退避 */);
    return () => events.kill();
}, [cliPath]);
```

`mutateTaskRunning` 直接改 `tasks` 数组里的 `status` 字段，触发 React 重渲染。这避免了 spawn `list --json`。

**ActionPanel**（按 §9.3 一致）：

| Action | Shortcut | 实现 |
|---|---|---|
| Run | Enter (idle) | `await runCli(cliPath, ["run", task.id])`。事件流会自动更新 status；超 2s 没收到 started 事件则兜底 `revalidate()` |
| Stop | Enter (running) | `runCli(["stop", task.id])`。Action 主键根据 task.status 动态切换（idle 时 Run 主、Stop 副；running 时 Stop 主、Run 副） |
| Restart | ⌘R | `runCli(["restart", task.id])` |
| Reveal in TaskTick | ⌘O | `runCli(["reveal", task.id])` |
| View Last Output | ⌘L | push `<LogsDetail id={task.id} />` |
| Copy Task ID | ⌘C | `Clipboard.copy(task.id)` |
| Refresh List | ⌘⇧R | `revalidate()` |

**toast 行为**：
- 用户 prefs `showCompletionToast=true`（默认）→ 动作发起前 `showToast({style: Animated, title: "Starting..."})` → 成功 `style: Success, title: "Started"` → 失败 `style: Failure, title: stderrFirstLine`
- TaskTick.app 端 `ActionToast` 系统通知是另一条独立的 banner，两者并存（一个在 Raycast 内，一个在系统右上角）

### 3.5 events.ts —— 子进程管理

```ts
import { spawn, ChildProcess } from "node:child_process";
import { EventEmitter } from "node:events";
import readline from "node:readline";

export class EventsStream extends EventEmitter {
    private proc: ChildProcess | null = null;
    private retries = 0;

    constructor(private cliPath: string) { super(); this.start(); }

    private start() {
        this.proc = spawn(this.cliPath, ["events"], { stdio: ["ignore", "pipe", "pipe"] });
        const rl = readline.createInterface({ input: this.proc.stdout! });
        rl.on("line", (line) => {
            try {
                const ev = JSON.parse(line);
                this.emit(ev.type, ev);
            } catch { /* 静默丢一行格式错乱的 */ }
        });
        this.proc.on("exit", (code) => {
            this.proc = null;
            if (code === 130 || code === 0) return; // 我们主动 kill 了
            // 异常退出 → 退避重连，最多 60s
            const backoff = Math.min(60_000, 1000 * 2 ** this.retries++);
            setTimeout(() => this.start(), backoff);
        });
    }

    kill() {
        if (this.proc) { this.proc.kill("SIGTERM"); this.proc = null; }
    }
}
```

要点：
- `proc.kill("SIGTERM")` 让 CLI 端干净退出
- 异常退出走 exponential backoff（防止 CLI 路径错误时打满 CPU）
- 主动 kill 后 `exit code === 130` 不重启

### 3.6 cli-detection.ts —— CLI 路径探测

按顺序：
1. preferences.cliPath（用户手填）
2. `/usr/local/bin/tasktick`
3. `/opt/homebrew/bin/tasktick`
4. `/Applications/TaskTick.app/Contents/MacOS/tasktick`

每一步用 `fs.access(path, X_OK)` 验证可执行。都没找到 → 返回 null，主视图渲染 `<CliNotFound />` detail 视图：

```
# tasktick CLI not found

To use this extension, enable the CLI in TaskTick:

1. Open TaskTick > Settings > Command Line
2. Click "Enable CLI..." and follow the instructions

If you have it installed at a custom location, set the
CLI Path in this extension's preferences.

[ Open TaskTick ]  [ Open Preferences ]
```

`Open TaskTick` action: `open -b com.lifedever.TaskTick`（GUI 没装也无所谓，open 会失败，Toast 提示去 task-tick.lifedever.com 下载）。

### 3.7 logs-detail.tsx —— View Last Output

调 `tasktick logs <id> --json` 拿 `ExecutionLog`（§5.4 schema）。根据 `prefs.logsFormat` 渲染：

- **text**：`<Detail markdown={renderText(log)} />`，把 `lines: [{ts, stream, text}]` 拼成时间戳 + stream 标记的代码块
- **json**：`<Detail markdown={"```json\n" + JSON.stringify(log, null, 2) + "\n```"} />`

ActionPanel 提供 Copy Output、Refresh、Reveal Task in TaskTick。"打开 TaskTick 的 Logs 窗口"留 v2（需要新的 URL Scheme 路由）。

### 3.8 错误处理

| 场景 | 行为 |
|---|---|
| CLI 未找到 | 渲染 CliNotFound 视图（见 3.6） |
| `list --json` 解析失败 | Toast: "Failed to load tasks (CLI version mismatch?)" |
| `run/stop/restart` 非 0 退出 | Toast: stderr 第一行 |
| events 流中断 | 静默重连（exponential backoff）；连续失败 > 3 次 → Toast 提示一次 |
| GUI 没跑、CLI 让 URL Scheme 唤起、10s 超时 | CLI 自己 exit 1 + stderr，Raycast 走通用 Toast 路径 |

---

## 4. 开发工作流

### 4.1 本地启动

1. **TaskTick.app 端**：`./scripts/build-dev.sh`，dev binary 在 `/Applications/TaskTick Dev.app/Contents/MacOS/tasktick-dev`。
2. **Raycast 端**：进 `tasktick-raycast/`，第一次跑 `npm install`，然后 `npm run dev`（Raycast 接管，自动 reload）。
3. **关键**：扩展 prefs 里 cliPath 设为 `/Applications/TaskTick Dev.app/Contents/MacOS/tasktick-dev`。

### 4.2 修改 TaskTick.app 后

每改一次 `Sources/CLI/...` 或 `Sources/Engine/CLIBridge.swift`：
- `./scripts/build-dev.sh` 重建 + 重启 dev
- Raycast 这边什么都不用做，cliPath 已经指向新的二进制

### 4.3 验收清单

- [ ] CLI 加 `events` 子命令后，`tasktick-dev events` 终端运行，期间在 GUI 里 Run 一个任务，stdout 立刻吐 `started` 行
- [ ] 改 ActionToast 后，GUI 里 Run/Stop/Restart 出现系统 banner
- [ ] CLI 改完，`tasktick-dev list --json | jq` 输出符合 §5.4 schema
- [ ] Raycast Search Tasks 打开 → List 渲染 → Enter 启动任务 → events 触发 status accessory 变化（idle → running → idle）
- [ ] kill GUI 进程，`tasktick-dev events` 不重启自己；Raycast 端的子进程检测到不到事件（行为上 List 不更新但不报错）
- [ ] cliPath 故意填错路径 → CliNotFound detail 出现
- [ ] 系统语言切到中文 → ActionToast 发的 banner 是中文（"已启动：X"）

---

## 5. 发布路径

### 5.1 第一阶段：本地 dev

- 仓库 `tasktick-raycast` push 到 GitHub `lifedever/tasktick-raycast`，public，README 标注"Store 审核中，目前需手装"
- 安装：`git clone && npm install && npm run dev`，Raycast 自动 import

### 5.2 第二阶段：Raycast Store

前置条件：
- TaskTick 1.5.x release 把 CLI 二进制带出去（cask 自动 symlink）
- 至少 4 张 1280x800 screenshot in `metadata/`
- README 完整、有 GIF 演示
- 走 `npm run lint` 干净

提 PR 到 `raycast/extensions` monorepo，typical review 1-2 周。

---

## 6. 测试策略

### 6.1 TaskTick.app

- `ActionToast` 单测：mock NotificationManager，验证不同 case 的 title/body
- `EventsCommand` 集成测：spawn CLI events → fake post taskStarted notification → assert NDJSON line
- `CLIBridge.handle` 加测：失败路径触发 `.failed(...)` toast

### 6.2 tasktick-raycast

最小测试集（不上 Jest，太重）：
- `lib/tasktick.ts` 的 stderr 解析：手测
- `lib/events.ts` 重连退避：mock 一个总是退出 1 的 cliPath，看重试次数
- `lib/cli-detection.ts` 路径探测：fixture 文件 + symlink

### 6.3 手测清单（pre-Store）

参考 CLAUDE.md 全新安装流程：
- 全新 mac 装 TaskTick.app（DMG）→ Settings 启 CLI → 装 Raycast 扩展（git）→ 跑通主路径
- 装 Raycast Store 上一版扩展，覆盖 install 新版（Store 审核后），数据兼容

---

## 7. 显式不做（v1 Non-Goals）

- 任务编辑 / 创建（CLI 都没有）
- 任务历史多次 execution 浏览（只看 last）
- 多任务批量操作
- 任务搜索高级语法（标签、kind 过滤），v1 让 Raycast 自带的模糊搜索处理任务名 → 已经够用
- 中文 UI
- Apple Shortcut / AppleScript 桥接
- Realtime stdout 流（`tail` 等价物的 Raycast UI），v2 再说
- `Create Task`、`Show Status`、`Run Last` 等额外命令，v1 单 `Search Tasks` 验证用户接受度后再扩

---

## 8. 风险与缓解

| 风险 | 缓解 |
|---|---|
| `tasktick-dev` 名字和 `tasktick` 不一致，将来发版后扩展用户混淆 | preferences.cliPath 描述里明示 dev 路径；CliNotFound 视图也提示 |
| events NDJSON 子进程管理 React 生命周期 + Raycast view 切换可能 leak | useEffect cleanup 确保 kill；测试 push/pop view 多次 |
| Distributed Notification 在用户启用 App Sandbox 后失效 | TaskTick 当前不 sandbox，无影响；未来若 sandbox 化用 app group 共享前缀 |
| Raycast `useExec` 不支持流式 stdin/stdout | 用 `node:child_process.spawn` 自己管，不走 useExec |
| Raycast 扩展 review 拒绝（i18n、icon 不达标） | review feedback 里改，不阻塞用户用 GitHub 版本 |
| ActionToast 太吵（每点一次都 banner） | 全局开关 `notificationsEnabled` 已存在；新增 per-task `notifyOnAction` 开关 → v2 再加，v1 全局即可 |

---

## 9. 实施顺序（给 writing-plans 的提示）

1. **TaskTick.app 端**：先加 `ActionToast`，hook 进 CLIBridge / GUI 按钮 → build-dev → 手测有 banner
2. **CLI 端**：加 `events` 子命令 → build-dev → `tasktick-dev events` 终端跑通
3. **Raycast 脚手架**：`npx create-raycast-extension` → 改 package.json → 引入基础 List
4. **Raycast 数据层**：`lib/tasktick.ts` + `lib/cli-detection.ts` + `lib/types.ts` → List 能展示静态数据
5. **Raycast 事件层**：`lib/events.ts` → mount / unmount / 重连工作
6. **Raycast 动作层**：ActionPanel 全部 6 个 action 接通
7. **Raycast 边界**：CliNotFound、错误 toast、logs detail
8. **打磨**：图标、README、screenshots、changelog
9. **GitHub release** Raycast 仓库
10. **TaskTick 1.5.x release**（带 CLI binary 给生产环境用户）
11. **Raycast Store PR**

每一步都能跑、能验。
