@echo off
:: Snapshot your LIVE Claude Code sessions (detects running processes + recent activity).
:: Usage: workspace-snapshot.bat                      (default: 120 min file window)
::        workspace-snapshot.bat 360                  (custom minutes for file activity detection)
::        workspace-snapshot.bat --auto               (non-interactive: save everything detected)
::        workspace-snapshot.bat --auto --open-only   (non-interactive: only open/likely-open tabs)
::        workspace-snapshot.bat --out <file>         (write snapshot somewhere other than workspace.json)
::        workspace-snapshot.bat --agent codex        (claude, codex or all -- which agent's sessions to capture)
::        workspace-snapshot.bat --history            (force the pre-shutdown history tier on)
::        workspace-snapshot.bat --no-history         (suppress the pre-shutdown history tier)
:: Note: for Task Scheduler, call powershell -File workspace-snapshot.ps1 --auto directly
::       (this .bat ends with `pause`, which would leave a scheduled task hanging).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0workspace-snapshot.ps1" %*
pause
