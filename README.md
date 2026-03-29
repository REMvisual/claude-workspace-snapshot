# claude-workspace-snapshot

Snapshot and restore your live Claude Code sessions as named, color-coded Windows Terminal tabs.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude-Code-blue)](https://claude.ai/code)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
[![Windows](https://img.shields.io/badge/platform-Windows-0078D6)](https://github.com/REMvisual/claude-workspace-snapshot)

## The Problem

You run 5-15 Claude Code sessions across different projects. After a restart, you lose all your tab layout -- working directories, session context, everything. Built-in `claude --resume` requires finding and typing 36-character UUIDs from a wall of text. This tool captures your entire workspace and rebuilds it in seconds.

## Install

### PowerShell (recommended)

```powershell
irm https://raw.githubusercontent.com/REMvisual/claude-workspace-snapshot/main/install.ps1 | iex
```

### Git Bash / WSL

```bash
curl -fsSL https://raw.githubusercontent.com/REMvisual/claude-workspace-snapshot/main/install.sh | bash
```

### Manual

```bash
git clone https://github.com/REMvisual/claude-workspace-snapshot.git
cp claude-workspace-snapshot/scripts/* ~/.claude/scripts/
```

## Usage

### Before Shutdown

Double-click `workspace-snapshot.bat` or run from terminal:

```
~/.claude/scripts/workspace-snapshot.bat
```

It detects your live sessions, shows them grouped by project, and saves to `~/.claude/workspace.json`.

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

### After Restart

Double-click `workspace-restore.bat` or run from terminal:

```
~/.claude/scripts/workspace-restore.bat
```

It opens Windows Terminal with one window per project group, each tab resuming its Claude Code session with the correct working directory, tab name, and color.

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

1. **Process detection** -- scans running `claude.exe` processes and extracts session IDs from `--resume` flags
2. **File activity detection** -- finds `.jsonl` session files modified in the last 30 minutes (catches IDE/SDK sessions that don't show as standalone processes)
3. **Metadata extraction** -- reads the first user message from each session's `.jsonl` file for the summary, working directory, and git branch
4. **Summary lookup** -- checks `sessions-index.json` for richer summaries when available
5. **Deterministic colors** -- assigns each project a stable color using a hash function over the project name (consistent across snapshots, no configuration needed)
6. **Group by project** -- sessions from the same working directory are grouped together
7. **Windows Terminal integration** -- restore builds `wt.exe` CLI commands with `--title`, `--tabColor`, and `-d` (working directory) for each tab
8. **Window separation** -- each project group opens as a separate Windows Terminal window

## Options

| Command | Description |
|---------|-------------|
| `workspace-snapshot.bat` | Snapshot with default 30-minute file activity window |
| `workspace-snapshot.bat 60` | Snapshot with 60-minute window (catches idle sessions) |
| `workspace-restore.bat` | Interactive restore with session/window picker |
| `workspace-restore.bat --all` | Restore everything without asking |

## Editing Your Workspace

After snapshotting, you can edit `~/.claude/workspace.json` to:
- Rename tabs (change the `tabName` field)
- Change tab colors (set `tabColor` to any `#RRGGBB` hex value)
- Rearrange sessions between groups
- Remove sessions you don't want to restore

## Requirements

- Windows 10 or 11
- [Windows Terminal](https://aka.ms/terminal) (wt.exe)
- PowerShell 5.1+ (built into Windows 10+)
- [Claude Code CLI](https://claude.ai/code) installed and on PATH

## Uninstall

```powershell
# PowerShell
~/.claude/scripts/uninstall.ps1

# Or manually
rm ~/.claude/scripts/workspace-snapshot.ps1
rm ~/.claude/scripts/workspace-snapshot.bat
rm ~/.claude/scripts/workspace-restore.ps1
rm ~/.claude/scripts/workspace-restore.bat
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

[MIT](LICENSE)
