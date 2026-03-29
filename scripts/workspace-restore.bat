@echo off
:: Restore Claude Code sessions from a workspace snapshot into Windows Terminal tabs.
:: Usage: workspace-restore.bat          (interactive - pick which sessions)
::        workspace-restore.bat --all    (restore all without asking)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0workspace-restore.ps1" %*
pause
