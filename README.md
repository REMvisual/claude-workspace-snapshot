<p align="center">
  <img src="assets/banner.svg" alt="claude-workspace-snapshot" width="100%">
</p>


[![Download Latest](https://img.shields.io/github/v/release/REMvisual/claude-workspace-snapshot?style=for-the-badge&label=Download&color=blue)](https://github.com/REMvisual/claude-workspace-snapshot/releases/latest)
![Views](https://komarev.com/ghpvc/?username=REMvisualclaude-workspace-snapshot&label=Views&color=brightgreen&style=for-the-badge)



## Why This Exists

You run multiple Claude Code (and now OpenAI Codex CLI) sessions across different projects. You restart your machine. Now every tab is gone. The built-in `claude --resume` / `codex resume` commands exist, but they need session IDs you have to dig out of a wall of text. For each session. One at a time.

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
irm https://raw.githubusercontent.com/REMvisual/claude-workspace-snapshot/master/install.ps1 | iex
```

**Git Bash / WSL:**

```bash
curl -fsSL https://raw.githubusercontent.com/REMvisual/claude-workspace-snapshot/master/install.sh | bash
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

It finds your live sessions -- Claude Code and Codex CLI both, by default -- groups them by project, and saves everything to `~/.claude/workspace.json`:

```
  WORKSPACE SNAPSHOT (live detection)
  Open terminal tabs (2): skywatch, taskflow-api
  4 sessions: 2 open for sure, 2 recent-only

  === OPEN (confirmed by running process) ===
  --- skywatch (#4A9BD9) ---
  1. cc Add hourly forecast caching to reduce API calls [OPEN] Mar 28 14:25
  2. cx Draft an OpenAPI schema for the forecast cache  [OPEN] Mar 28 14:22
  --- taskflow-api (#E67E22) ---
  3. cc Fix race condition in concurrent task assignment [OPEN] Mar 28 14:20

  === RECENT (file activity only -- may be closed) ===
  --- skywatch (#4A9BD9) ---
  4. cc Fix timezone handling in weather alerts          [F] Mar 28 14:10

  Save all? [Y/n/o=open only] or enter numbers (e.g. 1,3,5)
```

Each row is tagged `cc` (Claude Code) or `cx` (Codex) so a mixed window is easy to read at a glance. Codex liveness is detected the same way Claude's is -- by proof, not by guesswork: a running `codex.exe` holds an exclusive write lock on `~/.codex/thread-writer-locks/<session-id>.lock` for as long as the session is alive, so a stale lock file left behind by a session that already exited is never mistaken for an open one.

### Restore (after restart)

Double-click `workspace-restore.bat` or run it from terminal:

```
~/.claude/scripts/workspace-restore.bat
```

It rebuilds your Windows Terminal layout -- one window per project, each tab resuming its session with the correct directory, name, and color:

```
  WORKSPACE RESTORE
  Snapshot: 2026-03-28 14:30 (2h ago)

  Window 1: skywatch (#4A9BD9) -- 3 tab(s)
    1. [claude] skywatch: Add hourly forecast caching to reduc...
    2. [claude] skywatch: Fix timezone handling in weather aler...
    3. [codex] skywatch: Draft an OpenAPI schema for the forec...
  Window 2: taskflow-api (#E67E22) -- 1 tab(s)
    4. [claude] taskflow-api: Fix race condition in concurrent ...

  Options:
    Enter    = restore all windows
    w1,w2    = restore specific windows (e.g. w1,w3)
    1,3,5    = restore specific tabs (e.g. 1,3,5)
    n        = cancel
```

## How It Works

1. **Detects sessions** -- scans running `claude.exe`/`codex.exe` processes and recently active session files to find every live session, for either or both agents
2. **Extracts metadata** -- reads the session summary, working directory, and (for Claude) git branch from each session's data
3. **Groups and colors** -- clusters sessions by project and assigns each project a stable color based on its name
4. **Saves to JSON** -- writes everything to `~/.claude/workspace.json` (editable if you want to rename tabs or change colors)
5. **Restores via Windows Terminal** -- builds `wt.exe` commands with the right title, color, directory, and resume command (`claude --resume <id>` or `codex resume <id>`) for each tab

## Options

| Command | Description |
|---------|-------------|
| `workspace-snapshot.bat` | Snapshot with default 30-minute activity window |
| `workspace-snapshot.bat 60` | Snapshot with 60-minute window (catches idle sessions) |
| `workspace-snapshot.bat --auto` | Non-interactive: save everything detected (for scheduled tasks) |
| `workspace-snapshot.bat --auto --open-only` | Non-interactive: save only tabs that are confirmed/likely open |
| `workspace-snapshot.bat --out <file>` | Write the snapshot to an alternate file (named workspaces) |
| `workspace-snapshot.bat --agent claude\|codex\|all` | Capture only Claude sessions, only Codex sessions, or both (default `all`) |
| `workspace-snapshot.bat --history` | Force the pre-shutdown history tier on, even outside the normal 7-day window |
| `workspace-snapshot.bat --no-history` | Suppress the pre-shutdown history tier entirely |
| `workspace-restore.bat` | Interactive restore with session/window picker |
| `workspace-restore.bat --all` | Restore everything without prompting |
| `workspace-restore.bat --dry-run` | Print the exact `wt` commands without opening anything |
| `workspace-restore.bat --file <path>` | Restore from an alternate snapshot (e.g. a rotated backup) |

`[minutes]`, `--auto`, `--open-only` and `--out <file>` all still work exactly as before -- `--agent`, `--history` and `--no-history` are additive.

## Codex Support

Codex CLI sessions are captured and restored alongside Claude Code sessions -- same snapshot, same `workspace.json`, same restore run. A few things work differently under the hood because Codex's on-disk layout differs from Claude's:

- **Liveness** is proven by a held file lock, not a command-line argument: `codex.exe` carries no session id on its command line, but a live session holds an exclusive handle on `~/.codex/thread-writer-locks/<session-id>.lock` for as long as it runs. A lock *file* can be left behind after Codex exits; only a lock that is still *held* counts as open. The session's own working directory is then matched against the cwd of a `codex.exe` sitting inside a Windows Terminal tab to tell an on-screen session from a background/remote one.
- **A brand-new Codex session with no rollout file yet cannot be captured.** Codex only starts writing `~/.codex/sessions/.../rollout-*.jsonl` after the first exchange, and there is nothing to snapshot before that exists -- open a Codex tab and send at least one message before snapshotting if you want it captured.
- Codex rows have no git-branch or slug equivalent, so those fields are simply empty; the thread's own title (or its first typed prompt, or the project name, in that order) carries the display name instead.

## Snapshot Schema (`workspace.json`)

Every saved session record carries an `agent` field, either `"claude"` or `"codex"`. **A record with no `agent` field at all is treated as `"claude"` and restores exactly as it always has** -- snapshots taken before Codex support was added keep working unmodified; see [examples/workspace.json](examples/workspace.json) for a worked example with both agents in the same window group.

Every session also carries a `tier`, recording how sure the tool is that it was genuinely open:

| Tier | Meaning |
|------|---------|
| `open` | Confirmed by a running process sitting inside a terminal tab |
| `maybe` | An open tab was seen, but the session behind it had to be inferred by recency |
| `recent` | Only file activity was found -- the tab itself may already be closed |
| `background` | A live process was found, but not inside a terminal tab (a remote/daemon session) |
| `history` | Recovered from *before the last shutdown or blackout*, not from anything currently running |

`history` rows only appear when the pre-shutdown sweep runs (on by default within 7 days of the last boot, or forced with `--history`/suppressed with `--no-history`) and are always inferred -- so **`--auto` never saves a `history` row**, even if the sweep finds one. A `history` row whose `source` is `"snapshot"` was read back out of the pre-crash `workspace.json` itself and is shown as `(from snapshot)` -- strong evidence, since it is a record of what was genuinely open, not a guess from file timestamps.

## Automatic Backups

Every save first copies the existing `workspace.json` into
`~/.claude/workspace-backups/workspace-<timestamp>.json` (the newest 5 are kept),
and the new snapshot is written atomically — a crash mid-save can never destroy
your one good pre-reboot snapshot. Restore an older one with:

```
workspace-restore.bat --file %USERPROFILE%\.claude\workspace-backups\workspace-20260711-090000.json
```

## Auto-Snapshot on a Schedule

`--auto` makes the snapshot safe to run unattended: it saves everything it detects
without prompting, and if it finds *no* live sessions (e.g. it fires right after a
reboot) it exits without touching your existing `workspace.json`. To snapshot every
hour with Task Scheduler:

```
schtasks /create /tn "Claude Workspace Auto-Snapshot" /sc hourly ^
  /tr "powershell -NoProfile -ExecutionPolicy Bypass -File %USERPROFILE%\.claude\scripts\workspace-snapshot.ps1 --auto"
```

With that in place, a blackout can cost you at most an hour of workspace state.

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
- [OpenAI Codex CLI](https://github.com/openai/codex) installed and on PATH, only if you want Codex sessions captured/restored too -- Claude-only usage needs nothing extra

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

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude_Code-compatible-blueviolet.svg)](https://claude.ai/code)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

