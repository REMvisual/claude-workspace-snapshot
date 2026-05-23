# claude-workspace-snapshot

A pair of PowerShell scripts that snapshot live Claude Code sessions on Windows and restore them after a reboot. See `README.md` for the full overview.

Source of truth:
- `scripts/workspace-snapshot.ps1` — detects and saves live sessions (with history-recovery fallback)
- `scripts/workspace-restore.ps1` — rebuilds Windows Terminal tabs from `~/.claude/workspace.json`

## OpenViking Memory

This project uses OpenViking for persistent AI memory across sessions.

### How It Works
- **Session start**: OpenViking loads relevant memories from past sessions automatically via hooks
- **During session**: Use `/memory-recall <query>` to search past context when historical decisions, prior fixes, or patterns are relevant
- **Session end**: Conversation is automatically compressed and stored as long-term memory (profiles, preferences, entities, events, cases, patterns)

### Session Workflow
1. **Session start**: Global hook loads relevant OpenViking memories
2. **Before changes**: `/memory-recall <topic>` if related work might have happened before
3. **During work**: OpenViking records decisions passively — no action needed
4. **Session end**: Memory is committed automatically

### Files (NOT committed to git)
- `ov.conf` — OpenViking config with API keys
- `.openviking/` — Session state and memory cache

### Note on Beads
Beads task tracking is intentionally NOT initialized in this project — the global `bd` binary on this machine was built with `CGO_ENABLED=0`, which blocks embedded Dolt initialization for new projects. The project does not currently require task tracking; if needed later, rebuild `bd` with embedded-mode support and run `/beads init`.
