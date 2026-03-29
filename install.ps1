# claude-workspace-snapshot installer
# Usage: irm https://raw.githubusercontent.com/REMvisual/claude-workspace-snapshot/main/install.ps1 | iex
#
# Pin to a specific version:
#   $env:CWSS_BRANCH='v1.0.0'; irm https://raw.githubusercontent.com/REMvisual/claude-workspace-snapshot/main/install.ps1 | iex

$ErrorActionPreference = 'Stop'

$repo = 'REMvisual/claude-workspace-snapshot'
$branch = if ($env:CWSS_BRANCH) { $env:CWSS_BRANCH } else { 'main' }
$baseUrl = "https://raw.githubusercontent.com/$repo/$branch/scripts"
$scriptsDir = Join-Path $env:USERPROFILE '.claude\scripts'

Write-Host ""
Write-Host "  Installing claude-workspace-snapshot..." -ForegroundColor Cyan

if (-not (Test-Path $scriptsDir)) {
    New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
}

$files = @('workspace-snapshot.ps1', 'workspace-snapshot.bat', 'workspace-restore.ps1', 'workspace-restore.bat')

foreach ($f in $files) {
    $url = "$baseUrl/$f"
    $dest = Join-Path $scriptsDir $f
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
        Write-Host "  Downloaded: $f" -ForegroundColor Green
    } catch {
        Write-Host "  FAILED: $f - $_" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "  Installed to: $scriptsDir" -ForegroundColor Green
Write-Host ""
Write-Host "  Usage:" -ForegroundColor DarkGray
Write-Host "    Snapshot: $scriptsDir\workspace-snapshot.bat" -ForegroundColor White
Write-Host "    Restore:  $scriptsDir\workspace-restore.bat" -ForegroundColor White
Write-Host ""
