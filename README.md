# claude-workspace-snapshot

**Save and restore your Claude Code sessions as color-coded Windows Terminal tabs.** Stop losing your workspace after every restart.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude_Code-compatible-blueviolet.svg)](https://claude.ai/code)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
![Views](https://komarev.com/ghpvc/?username=REMvisual&label=views&color=brightgreen&style=flat)
[![Download Latest](https://img.shields.io/github/v/release/REMvisual/claude-workspace-snapshot?style=for-the-badge&label=Download&color=blue)](https://github.com/REMvisual/claude-workspace-snapshot/releases/latest)
[![Total Downloads](https://img.shields.io/github/downloads/REMvisual/claude-workspace-snapshot/total?style=for-the-badge)](https://github.com/REMvisual/claude-workspace-snapshot/releases)
---

## Why This Exists

You run multiple Claude Code sessions across different projects. You restart your machine. Now every tab is gone. The built-in `claude --resume` command exists, but it needs 36-character UUIDs that you have to dig out of a wall of text. For each session. One at a time.

This tool fixes that. Two scripts. One saves your workspace, the other brings it back.

## Before / After

```
BEFORE:  Restart -> lose 15 tabs -> manually find UUIDs -> type claude --resume for each one
AFTER:   Restart -> double-click restore.bat -> all tabs back in 5 seconds
```

## Quick Demo

```
1. Work across multiple projects in Claude Code
2. Before shutdown:  run snapshot.bat
3. After restart:    run restore.bat  ->  everything's back
```

That's it. Your sessions come back in the right directories, with the right tab names, grouped by project, color-coded.

## Install

**PowerShell (recommended):**

```powershell
irm https://raw.githubusercontent.com/REMvisual/claude-workspace-snapshot/main/install.ps1 | iex
```

**Git Bash / WSL:**

```bash
curl -fsSL https://raw.githubusercontent.com/REMvisual/claude-workspace-snapshot/main/install.sh | bash
```

**Manual:**

```bash
git clone https://github.com/REMvisual/claude-workspace-snapshot.git
cp claude-workspace-snapshot/scripts/* ~/.claude/scripts/
```

## Usage

### Snapshot (before shutdown)

Double-click `workspace-snapshot.bat` or run it from terminal:

```
~/.claude/scripts/workspace-snapshot.bat
```

It finds your live sessions, groups them by project, and saves everything to `~/.claude/workspace.json`:

```
  WORKSPACE SNAPSHOT (live detection)
  13 live sessions (8 from processes, 5 from file activity)

  --- skywatch (#4A9BD9) ---
  1. Add hourly forecast caching to reduce API calls [P] Mar 28 14:25
  2. Fix timezone handling in weather alerts           [F] Mar 28 14:10
  --- taskflow-api (#E67E22) ---
  3. Fix race condition in concurrent task assignment  [P] Mar 28 14:20
  4. Add WebSocket notifications for task updates      [F] Mar 28 13:45

  Save all? [Y/n] or enter numbers (e.g. 1,3,5)
```

### Restore (after restart)

Double-click `workspace-restore.bat` or run it from terminal:

```
~/.claude/scripts/workspace-restore.bat
```

It rebuilds your Windows Terminal layout -- one window per project, each tab resuming its session with the correct directory, name, and color:

```
  WORKSPACE RESTORE
  Snapshot: 2026-03-28 14:30 (2h ago)

  Window 1: skywatch (#4A9BD9) -- 2 tab(s)
    1. skywatch: Add hourly forecast caching to reduc...
    2. skywatch: Fix timezone handling in weather aler...
  Window 2: taskflow-api (#E67E22) -- 2 tab(s)
    3. taskflow-api: Fix race condition in concurrent ...
    4. taskflow-api: Add WebSocket notifications for t...

  Options:
    Enter    = restore all windows
    w1,w2    = restore specific windows (e.g. w1,w3)
    1,3,5    = restore specific tabs (e.g. 1,3,5)
    n        = cancel
```

## How It Works

1. **Detects sessions** -- scans running `claude.exe` processes and recently active session files to find every live session
2. **Extracts metadata** -- reads the session summary, working directory, and git branch from each session's data
3. **Groups and colors** -- clusters sessions by project and assigns each project a stable color based on its name
4. **Saves to JSON** -- writes everything to `~/.claude/workspace.json` (editable if you want to rename tabs or change colors)
5. **Restores via Windows Terminal** -- builds `wt.exe` commands with the right title, color, directory, and `--resume` flag for each tab

## Options

| Command | Description |
|---------|-------------|
| `workspace-snapshot.bat` | Snapshot with default 30-minute activity window |
| `workspace-snapshot.bat 60` | Snapshot with 60-minute window (catches idle sessions) |
| `workspace-restore.bat` | Interactive restore with session/window picker |
| `workspace-restore.bat --all` | Restore everything without prompting |

## Editing Your Workspace

After snapshotting, edit `~/.claude/workspace.json` directly to:

- Rename tabs (change the `tabName` field)
- Change tab colors (set `tabColor` to any `#RRGGBB` value)
- Rearrange or remove sessions

## Requirements

- Windows 10 or 11
- [Windows Terminal](https://aka.ms/terminal) (wt.exe)
- PowerShell 5.1+ (built into Windows 10+)
- [Claude Code CLI](https://claude.ai/code) installed and on PATH

## Uninstall

```powershell
~/.claude/scripts/uninstall.ps1
```

Or remove the files manually:

```powershell
rm ~/.claude/scripts/workspace-snapshot.ps1
rm ~/.claude/scripts/workspace-snapshot.bat
rm ~/.claude/scripts/workspace-restore.ps1
rm ~/.claude/scripts/workspace-restore.bat
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines. PRs are welcome.

## License

[MIT](LICENSE)

---

If this tool saved you time, [give it a star](https://github.com/REMvisual/claude-workspace-snapshot). It helps others find it.
