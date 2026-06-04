# Open-Certainty Tiers in workspace-snapshot

**Date:** 2026-06-03
**Status:** Approved
**Script:** `scripts/workspace-snapshot.ps1`

## Problem

1. **Name mismatch.** Windows Terminal tab titles (e.g. "TREES", "scalability") are set
   live by Claude Code / happy-coder via terminal escape sequences and the
   `mcp__happy__change_title` tool. They are never persisted to disk. The snapshot
   instead displays `sessions-index.json` summaries and project folder names — so the
   list looks nothing like the user's tabs.
2. **False "live" sessions.** Process detection only matched `claude.exe --resume <uuid>`,
   which catches almost nothing (interactive tabs run bare `claude.exe`, or Claude
   wrapped in happy-coder node processes). Everything fell through to file-activity
   detection, which also sweeps up the Claude daemon, background forks, subagent
   writers, and already-closed sessions. Result: "12 live sessions" when ~6 tabs are open.

## Key discoveries (verified on this machine)

- Tabs running Claude via **happy-coder** form the chain
  `WindowsTerminal → pwsh → node happy-coder/bin (pid N) → node claude_local_launcher.cjs`.
  The file `~/.happy/logs/*-pid-N.log` contains `"sessionId": "<claude-session-uuid>"`
  entries — the **last** uuid in the log is the session currently hosted by that tab.
  Verified 5/5 live tabs map deterministically.
- Bare `claude.exe` tabs expose no session id in the command line, but their **count**
  is knowable (ancestry reaches `WindowsTerminal.exe`).
- **UIAutomation** (`CASCADIA_HOSTING_WINDOW_CLASS` → TabItem descendants) enumerates
  the real open tab titles. Used for display/ground truth only — no title→session
  matching (explicitly rejected as unreliable).
- The Claude daemon (`claude.exe daemon run`), bg pty hosts (`--bg-pty-host`), and
  daemon-spawned forks (`--session-id <uuid> --fork-session`, ancestry NOT under
  WindowsTerminal) are background infrastructure, not tabs.

## Design

### Detection (STEP 1 rework)

Snapshot the full process table once into a hashtable; helper
`Test-UnderWindowsTerminal` walks `ParentProcessId` (max 12 levels) looking for
`WindowsTerminal.exe`.

- **Method A (improved):** `claude.exe` processes. Skip infra (`daemon run`,
  `--bg-pty-host`). Extract uuid from `--session-id <uuid>` or `--resume <uuid>`.
  - uuid + under WT → **confirmed open**
  - uuid + not under WT → **background**
  - no uuid + under WT → increment `bareOpenCount`
- **Method H (new, replaces old Method C):** for each running `node.exe` whose command
  line contains `happy-coder`, find `~/.happy/logs/*-pid-<pid>.log` (newest if several).
  Last `"sessionId": "<uuid>"` in the log → **confirmed open** (under WT) or
  **background** (remote/phone session).
- **Method B (unchanged):** `.jsonl` files modified in the last `$Minutes` →
  candidates for the **recent** tier.
- **UIAutomation:** collect open tab titles for the header line. Failure-safe
  (try/catch, degrades to no header line).

### Tiers

| Tier | Tag | Meaning |
|------|-----|---------|
| `open` | `[OPEN]` (green) | Session uuid confirmed by a running tab process |
| `maybe` | `[OPEN?]` (yellow) | Top `bareOpenCount` most-recent unconfirmed sessions — fills the tabs we know exist but can't identify |
| `recent` | `[F]` (gray) | File activity only — may already be closed |
| `background` | `[BG]` (dark) | Running but not a terminal tab (happy remote, daemon forks) |

Display order: open → maybe → recent → background, each with a section banner;
project group headers within each tier as before. Global numbering preserved for
selection. Header shows:
`Open terminal tabs (N): TREES, scalability, ...` plus per-tier counts.

### Save

- Prompt gains an `o` option: `Save all? [Y/n/o=open only]` — `o` saves only
  `open` + `maybe` tiers.
- Each saved session gains a `tier` field in `workspace.json` (ignored by restore —
  additive, non-breaking).

### Out of scope

- Fuzzy/manual matching of tab titles to sessions (user chose tiers-only).
- History-recovery mode: unchanged, still tags `[H]`.
- Restore-side changes.

## Error handling

- All process/log/UIA probing wrapped in try/catch or `-ErrorAction SilentlyContinue`;
  any failure degrades to the previous behavior (file-activity only, no header).
- Pid reuse: only logs whose pid belongs to a *currently running* happy node process
  are consulted; newest log wins when several share a pid.

## Testing

Manual: run `workspace-snapshot.bat` with live tabs (happy-wrapped + bare claude.exe)
and verify tier assignment matches reality; pipe `n` to cancel before saving.
