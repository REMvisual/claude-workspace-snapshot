# Contributing to claude-workspace-snapshot

Thank you for considering a contribution. This project aims to stay small, focused, and reliable on Windows. These guidelines help keep things moving smoothly.

## Getting Started

1. Fork the repository.
2. Create a feature branch from `main`: `git checkout -b your-feature-name`
3. Make your changes.
4. Test locally (see [Testing](#testing) below).
5. Open a pull request against `main`.

## What Makes a Good Contribution

**Welcome:**

- Bug fixes with clear reproduction steps in the PR description.
- New session detection methods (e.g., detecting Claude sessions launched from VS Code, Cursor, or other editors).
- Improvements to tab naming, color assignment, or group sorting logic.
- Platform support expansions (e.g., PowerShell 7 compatibility, Windows Terminal Preview support).
- Documentation improvements, typo fixes, and better examples.
- Performance improvements for users with many sessions (50+).

**Will not be merged:**

- Hard dependencies on external tools that are not bundled with Windows 10 (no Python, no Node.js, no third-party modules). The tool must work with PowerShell 5.1 and built-in Windows utilities only.
- Changes that break Windows 10 compatibility. Windows 10 with PowerShell 5.1 is the baseline.
- Removal of interactive prompts. The snapshot and restore scripts intentionally ask for confirmation before acting. Non-interactive flags (like `--all`) are acceptable as additions, not replacements.
- Telemetry, analytics, or any network calls. This tool is entirely local.
- Changes that read or transmit session content. The tool reads metadata (session IDs, working directories, first-prompt summaries) but must never export full conversation history.

## Testing

There is no automated test suite. Testing is manual.

**Before submitting a PR, verify the following on Windows 10 or 11:**

1. Open 2-3 Claude Code sessions in different project directories.
2. Run `workspace-snapshot.bat` from a terminal.
3. Confirm all live sessions appear in the output with correct project names, summaries, and detection sources (`[P]` for process, `[F]` for file activity).
4. Accept the save prompt.
5. Confirm `~/.claude/workspace.json` was written and contains the expected sessions.
6. Close all Claude Code sessions and terminal windows.
7. Run `workspace-restore.bat` from a terminal.
8. Confirm Windows Terminal opens with the correct number of windows, tabs, working directories, tab names, and tab colors.
9. Confirm each tab resumes the correct Claude Code session.

If your change involves the file activity detection method, also test with the custom time window: `workspace-snapshot.bat 60`.

## Code Style

- **PowerShell best practices.** Use approved verbs (`Get-`, `Set-`, `Test-`), full cmdlet names (not aliases), and consistent formatting.
- **Descriptive variable names.** `$sessionJsonlFile` over `$f`. `$recentCutoff` over `$rc`.
- **Error handling.** Use `-ErrorAction SilentlyContinue` on operations that may fail on some systems (e.g., `Get-CimInstance`, `Get-ChildItem` on locked directories). Do not let the script crash on a missing file or permission issue.
- **No external dependencies.** Only use PowerShell 5.1 built-in cmdlets and .NET Framework classes available on stock Windows 10.
- **Comments.** Explain *why*, not *what*. `# Fall back to first prompt if no summary in sessions-index.json` is useful. `# Loop through sessions` is not.
- **No emojis.** Not in code, not in comments, not in output strings.

## Commit Messages

Use concise, imperative-mood commit messages:

```
fix: handle sessions with missing cwd field
feat: add detection for VS Code integrated terminal sessions
docs: clarify custom time window usage in README
```

## Questions

Open an issue if something is unclear. There is no mailing list or Discord -- GitHub Issues is the right place for all discussion.
