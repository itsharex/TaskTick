# TaskTick

<p align="center">
  <img src="docs/icon.svg" width="128" height="128" alt="TaskTick Icon">
</p>

<p align="center">
  <strong>A native macOS app for managing scheduled tasks.</strong><br>
  <em>macOS 原生定时任务管理，开箱即用，菜单栏常驻。</em>
</p>

<p align="center">
  <a href="https://github.com/lifedever/TaskTick/releases">Download</a> ·
  <a href="https://lifedever.github.io/TaskTick/">Website</a> ·
  <a href="https://lifedever.github.io/sponsor/">Sponsor</a>
</p>

---

## Features

- **Menu Bar Resident** — runs in background, always accessible from menu bar
- **Flexible Scheduling** — cron expressions (with visual editor & presets) or fixed intervals
- **Script Execution** — inline scripts or local files (.sh, .py, .rb, .js)
- **Execution Logs** — stdout/stderr capture, exit codes, duration tracking
- **Notifications** — macOS system notifications on success/failure
- **i18n** — English & Simplified Chinese, switchable in-app
- **Auto Updates** — checks GitHub Releases for new versions
- **macOS 26 Ready** — liquid glass effects on supported systems

## Requirements

- macOS 15 (Sequoia) or later
- Apple Silicon or Intel Mac

## Install

### Download

Grab the latest `.dmg` from [Releases](https://github.com/lifedever/TaskTick/releases).

### Build from Source

```bash
git clone https://github.com/lifedever/TaskTick.git
cd TaskTick
swift build -c release
swift run
```

## Tech Stack

- **SwiftUI** — declarative UI framework
- **SwiftData** — persistence (SQLite under the hood)
- **Swift Package Manager** — build system & dependency management

## License

MIT © [lifedever](https://github.com/lifedever)
