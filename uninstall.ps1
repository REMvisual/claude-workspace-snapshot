# claude-workspace-snapshot uninstaller

$scriptsDir = Join-Path $env:USERPROFILE '.claude\scripts'
$files = @('workspace-snapshot.ps1', 'workspace-snapshot.bat', 'workspace-restore.ps1', 'workspace-restore.bat')

Write-Host ""
Write-Host "  Uninstalling claude-workspace-snapshot..." -ForegroundColor Cyan

foreach ($f in $files) {
    $path = Join-Path $scriptsDir $f
    if (Test-Path $path) {
        Remove-Item $path -Force
        Write-Host "  Removed: $f" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "  Uninstalled. Your workspace.json was not removed." -ForegroundColor DarkGray
Write-Host ""
