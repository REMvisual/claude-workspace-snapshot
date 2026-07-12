# Hardening & Refactor Design — claude-workspace-snapshot

Date: 2026-07-11
Status: approved (autonomous session; user directive: "strengthen, refactor and make this app as powerful and robust as possible")

## Goals

Make both scripts robust against hostile/degraded input, fix documented-but-broken
flags, remove duplication, and add the automation features that make the tool
actually reliable across a blackout — without touching the hard-won live-detection
logic (Methods A / H / C / UIAutomation), which is preserved verbatim.

## Changes

### Both scripts
- **Robust argument parsing.** Verified live on Windows PowerShell 5.1: `--all`
  already binds (the binder reads `--all` as parameter `-all`), but hyphenated
  flags (`--open-only`, `--dry-run`, `--file`) do not, and `[CmdletBinding()]`
  is a trap — its common parameters make `--out` ambiguous against
  `-OutVariable`/`-OutBuffer`. Chosen design: plain (non-advanced) param block
  so flags matching a param name bind natively, plus a manual `$args` parser
  for the hyphenated variants and bare integers (= minutes). Unknown args
  print usage and exit 1. PowerShell-style named params keep working.
- **Title sanitization.** `Get-SafeTabName` strips control chars, `"` `<` `>`
  `|` `&` `^` `%`, converts `;` to `,`, collapses whitespace. Applied when
  saving tab names (snapshot) and again defensively on every title read from
  the user-editable workspace.json (restore).
- **Consistent exit codes**: 0 = success or user cancel, 1 = error/bad args.
- PowerShell 5.1 compatible throughout (no ternary, no `??`).

### workspace-snapshot.ps1
- **Single filesystem index.** One recursive `*.jsonl` scan feeds Method B,
  Method C, history mode, and the per-session metadata lookup (previously one
  recursive scan per live session plus per-project scans).
- **`-Auto` (`--auto`)**: non-interactive; prints the listing, saves all
  detected sessions without prompting. Enables Task Scheduler use. In Auto
  mode with zero live sessions the script exits 0 **without** touching
  workspace.json and without entering history mode (a scheduled run after
  reboot must never clobber the good pre-reboot snapshot with junk).
- **`-OpenOnly` (`--open-only`)**: restrict to `open`/`maybe` tiers (the tabs
  actually on screen). Composable with `-Auto`.
- **`-OutFile <path>` (`--out`)**: write somewhere other than
  `~/.claude/workspace.json` (named workspaces, testing).
- **Backup rotation + atomic write.** Before overwriting, the existing target
  is copied to `<target-dir>/workspace-backups/workspace-<mtime>.json`; the
  newest 5 backups are kept. The new file is written to `*.tmp` then moved
  into place, so a crash mid-write can't leave a truncated workspace.json.

### workspace-restore.ps1
- **Fix `--all`** (see argument parsing above).
- **`-DryRun` (`--dry-run`)**: print the exact `wt` command lines instead of
  executing them. Makes the restore path testable and auditable.
- **`-Path <file>` (`--file`)**: restore from an alternate snapshot file
  (pairs with snapshot `-OutFile`, and lets users restore a rotated backup).
- **Validation pass before anything opens** (workspace.json is user-editable):
  - `sessionId` must match the UUID regex — otherwise the entry is skipped
    with a warning (also blocks command injection via a tampered file).
  - `projectPath` missing on disk → warn, fall back to `%USERPROFILE%` so the
    tab still opens with the session resumed.
  - `tabColor` must match `#RRGGBB` → else fall back to group color, else
    default palette blue.
  - Session `.jsonl` no longer on disk → flagged `[missing]` in the listing
    (restore still attempts; `cmd /k` keeps the window open so claude's own
    error is visible and the user has a shell in the right directory).
  - `claude` not on PATH → upfront warning instead of N broken tabs.
- **Single window opener.** The duplicated wt-command builder (group path vs
  individual-tab path) collapses into one `Open-WorkspaceWindows` function fed
  by normalized session objects.
- **`wt -w new`** on every window so groups open as separate windows even when
  the user's Windows Terminal `windowingBehavior` is `useAnyExisting`.

### Docs
- README: new flags, backup rotation, Task Scheduler auto-snapshot recipe.
- examples/workspace.json: refreshed to current schema (tier/tabLabel fields).
- .bat headers updated.

## Approaches considered
1. **Harden in place, two self-contained scripts** (chosen) — keeps the
   install story (copy 4 files) and the proven detection logic intact.
2. Shared dot-sourced common module — less duplication but adds an install
   file and load-order failure mode for ~40 shared lines. Rejected.
3. Rewrite as a PowerShell module with Pester tests — heaviest option;
   over-engineering for a 2-script tool distributed by raw-file download.

## Testing
- AST parse both scripts (syntax gate).
- Hostile fixture workspace.json (quotes/semicolons/%/bad uuid/dead dir/bad
  color) → `restore --dry-run --all --file <fixture>`: verify sanitization,
  skips, fallbacks, `-w new`, and that nothing launches.
- `snapshot --auto --out <scratch>`: real end-to-end detection on this
  machine; verify valid JSON, this session detected, real workspace.json
  untouched; run twice → backup rotation exercised.
- Verify `--all` actually binds (the bug this fixes) on Windows PowerShell 5.1.
