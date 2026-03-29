@echo off
:: Snapshot your LIVE Claude Code sessions (detects running processes + recent activity).
:: Usage: workspace-snapshot.bat           (default: 30 min file window)
::        workspace-snapshot.bat 60        (custom minutes for file activity detection)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0workspace-snapshot.ps1" %*
pause
