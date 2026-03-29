# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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
