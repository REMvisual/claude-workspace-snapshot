# History Recovery Mode for workspace-snapshot

**Date:** 2026-05-23
**Status:** Approved
**Scope:** `scripts/workspace-snapshot.ps1`

## Problem

The current snapshot flow assumes the user runs `workspace-snapshot.bat` *before* shutting down, so live process + recent-file detection finds open Claude sessions and saves them to `workspace.json`. `workspace-restore.bat` then reopens them after restart.

This fails for unplanned terminations: a power blackout, a forced Windows Update reboot, or a crash. After the machine comes back up, no Claude sessions are running. Running the snapshot script in that state currently prints:

```
  No live Claude sessions detected.
  (checked running processes + files modified in last 30 min)
```

…and exits. The user has lost their tab layout with no fallback — even though every session's `.jsonl` file still exists on disk, untouched.

## Goals

1. When no live sessions are detected, offer a history-recovery fallback that reconstructs what was open right before the restart.
2. Never override the live-detection path. Live sessions always win; history mode is only reachable when zero live sessions exist.
3. Produce a `workspace.json` in the exact same shape as the live path so `workspace-restore.bat` needs no changes.

## Non-goals

- No new flags or modes for the common case. The feature is purely fallback.
- No changes to `workspace-restore.ps1` or `workspace-restore.bat`.
- No automatic restore — user still confirms before saving, same as live mode.

## Trigger

In `workspace-snapshot.ps1`, the block at lines 60–66:

```powershell
if ($liveIds.Count -eq 0) {
    Write-Host "  No live Claude sessions detected."
    exit 0
}
```

…is replaced with a prompt:

```
  No live Claude sessions detected.

  Look at recent history? [Y/n]
```

- Default `Y` (Enter) → enter history mode.
- `n` → exit with the same "no live sessions" message as today.

This is the only entry point to history mode. There is no CLI flag.

## History Scoping

Once history mode is entered:

1. **Boot-time window (primary).** Read `(Get-CimInstance Win32_OperatingSystem).LastBootUpTime`. Collect `.jsonl` files whose `LastWriteTime` falls in `[boot - 2h, boot]`. These are the sessions that were alive in the two hours leading up to the restart.
2. **Recent-activity fallback.** If the primary window returns zero candidates, OR if the last boot was more than 7 days ago, fall back to the 20 most recently modified `.jsonl` files across `~/.claude/projects/`, filtered to files modified within the last 30 days.
3. **Same filters as live mode.** Sidechain sessions, missing-cwd entries, and missing-firstPrompt entries are excluded by the existing metadata-build loop. History mode reuses that loop unchanged.

Both branches feed the same downstream display/save logic.

## UI

The display block is reused with three visible differences so the user knows they're in recovery mode, not snapshotting live work:

- Header color: yellow (`Yellow`) instead of cyan (`Cyan`).
- Header text: `WORKSPACE SNAPSHOT (history recovery)` instead of `(live detection)`.
- Subtitle: one of
  - `N sessions from before last boot (Mar 29 14:05 — 2h window)`
  - `N most recently active sessions (fallback — last boot was 9 days ago)`
  - `N most recently active sessions (fallback — no sessions found near boot time)`
- Source tag per row: `[H]` (history) instead of `[P]` / `[F]`.

The `Save all? [Y/n] or numbers` prompt is identical.

## Save Behavior

Identical to the live path. Selected sessions are grouped by project, written to `~/.claude/workspace.json` in the same schema. `workspace-restore.bat` consumes it without knowing whether the source was live or history.

## Edge Cases

| Condition | Behavior |
|-----------|----------|
| Boot-time window returns 0 sessions | Fall back to top-20 recent (30-day cap). |
| Top-20 fallback returns 0 sessions | Print `No historical sessions found in ~/.claude/projects/.` and exit 0. |
| Sessions older than 30 days | Excluded from fallback to avoid dredging up ancient junk. |
| `workspace.json` exists and was modified after last boot | Before prompting, print a one-line tip: `Tip: workspace.json exists from <timestamp> — workspace-restore.bat may already have what you need.` Still offer history mode. |
| User answers `n` to the history prompt | Exit with the existing "no live sessions" message. No JSON written. |
| Sidechain / missing-cwd / no-firstPrompt sessions | Skipped by the existing metadata loop — same behavior as live. |
| User selects nothing in the save prompt | Existing "No valid sessions selected" message, no JSON written. |

## Safety

- Reads only. The script never writes to or modifies any `.jsonl` file.
- No interaction with running Claude processes. History mode by definition only runs when none exist.
- `workspace.json` is written only after explicit user confirmation (same as live path).

## Out of Scope

- Heuristics to merge live + historical (e.g., "I see 2 live and remember 10 from last boot, want both?"). Live always wins; history is fallback only.
- Per-session preview of conversation content.
- Cross-machine recovery (cloud sync of workspace.json).
