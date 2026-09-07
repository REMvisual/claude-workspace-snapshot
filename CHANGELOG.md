# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.3.0] - 2026-09-07

### Added
- Codex CLI capture and restore alongside Claude Code, selectable with `--agent claude|codex|all` (default `all`). Every session record now carries an `agent` field (`claude` or `codex`); a record with no `agent` field is treated as `claude` for backwards compatibility.
- Codex liveness is proven by a held exclusive write lock on `~/.codex/thread-writer-locks/<session-id>.lock` -- a stale lock *file* left behind after Codex exits is never mistaken for an open session, since only a lock still *held* counts.
- Real forensic pre-shutdown history recovery, replacing the old best-effort history mode: the actual shutdown time now comes from Windows System event log Event 6008, and the pre-crash `workspace.json` (a record of what was genuinely open, not an inference) is consulted before falling back to file-activity timing. Recovered rows are shown under a `history` tier (`[H]`), tagged `(from snapshot)` when backed by the pre-crash snapshot.
- `--history` / `--no-history` flags to force the pre-shutdown sweep on or off outright.

### Fixed
- **Corrected shutdown-time source.** The original history-recovery design assumed Event 41 carried the shutdown timestamp; it does not -- on this platform Event 41's properties are scalar zeros and it is corroboration only ("the shutdown was unexpected"), never a time source. The real timestamp for an unexpected shutdown is packed into Event 6008's `Properties[7]` as a SYSTEMTIME blob, and 6008's own `TimeCreated` is written only after the *next* boot, so it cannot be used directly either. Clean shutdowns (1074/6006) are unaffected -- their `TimeCreated` was always correct.

### Safety
- `--auto` never persists a `history` row, even when the sweep finds one -- every history row is an inference, and a scheduled unattended run must never silently launder a guess into a saved fact.
- Under `--auto` only, a save that would strictly shrink a `workspace.json` that still predates the last boot is declined, with an on-screen explanation, rather than overwriting the last known-good pre-reboot snapshot with a smaller one.
- `workspace-restore.ps1` resolves each row's resume command from a fixed allowlist (`claude --resume <id>`, `codex resume <id>`); an unrecognized `agent` value is skipped, and the value itself is never echoed to the console or interpolated into a command line.

### Known limitation
- A just-launched Codex session that has not yet written its first rollout file cannot be captured -- there is nothing on disk to snapshot until the first exchange happens.

## [1.2.0] - 2026-05-23

### Added
- History recovery mode: when no live sessions are detected (after reboot, blackout, or forced update), the snapshot script offers to scan recent history. Uses a 2-hour window before the last system boot, with a top-20 most-recently-active fallback. Live detection always wins — history is fallback only.

### Improved
- Snapshot output distinguishes history mode (yellow header, `[H]` source tag) from live mode (cyan header, `[P]`/`[F]` tags).
- Friendly tip when a pre-reboot `workspace.json` already exists.

## [1.1.0] - 2026-03-29

### Added
- SDK session detection (Method C) for IDE plugins and SDK wrappers that don't spawn `claude.exe`

### Fixed
- Tab titles now persist via `--suppressApplicationTitle` (Claude Code no longer overrides them)
- Integer overflow in `Get-ProjectColor` hash function on longer project names
- Removed all hardcoded project names from color assignment

### Improved
- README with Before/After comparison, download badges, and simpler tone
- Release includes downloadable zip with flat file layout

## [1.0.0] - 2026-03-28

### Added
- Live session detection via running `claude.exe` process inspection
- Fallback detection via recently-modified `.jsonl` session files (catches IDE/SDK sessions)
- Session metadata extraction from `.jsonl` files (first prompt, working directory, git branch)
- Summary enrichment from `sessions-index.json` when available
- Deterministic per-project color assignment using hash function (no configuration needed)
- Interactive session selection on snapshot (save all or pick specific sessions)
- Project-based grouping (sessions from the same directory grouped together)
- Multi-window restore (each project group opens as a separate Windows Terminal window)
- Selective restore by window (`w1,w3`) or individual tab (`1,3,5`)
- Tab names, colors, and working directories preserved across snapshot/restore
- Legacy format support (flat `sessions` array auto-upgraded to `groups`)
- `.bat` wrappers for double-click execution
- Stale snapshot warning (48+ hours old)
- Install/uninstall scripts for PowerShell and Git Bash
