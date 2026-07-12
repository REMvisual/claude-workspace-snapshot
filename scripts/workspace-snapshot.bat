@echo off
:: Snapshot your LIVE Claude Code sessions (detects running processes + recent activity).
:: Usage: workspace-snapshot.bat                      (default: 30 min file window)
::        workspace-snapshot.bat 60                   (custom minutes for file activity detection)
::        workspace-snapshot.bat --auto               (non-interactive: save everything detected)
::        workspace-snapshot.bat --auto --open-only   (non-interactive: only open/likely-open tabs)
::        workspace-snapshot.bat --out <file>         (write snapshot to an alternate file)
:: Note: for Task Scheduler, call powershell -File workspace-snapshot.ps1 --auto directly
::       (this .bat ends with `pause`, which would leave a scheduled task hanging).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0workspace-snapshot.ps1" %*
pause
