# workspace-restore.ps1
# Reopens Claude Code sessions in Windows Terminal tabs from a workspace snapshot.
# Each group becomes a separate Windows Terminal window.
# Tab names and colors are preserved from the snapshot.
#
# Usage: workspace-restore.bat          (interactive - pick which groups/sessions)
#        workspace-restore.bat --all    (restore everything without asking)

param(
    [switch]$All
)

$claudeDir = Join-Path $env:USERPROFILE '.claude'
$workspaceFile = Join-Path $claudeDir 'workspace.json'

# Check workspace exists
if (-not (Test-Path $workspaceFile)) {
    Write-Host ""
    Write-Host "  No workspace.json found." -ForegroundColor Yellow
    Write-Host "  Run workspace-snapshot.bat first to capture your sessions." -ForegroundColor DarkGray
    Write-Host ""
    exit 1
}

# Check wt.exe exists
$wt = Get-Command wt -ErrorAction SilentlyContinue
if (-not $wt) {
    Write-Host ""
    Write-Host "  Windows Terminal (wt.exe) not found." -ForegroundColor Red
    Write-Host "  Install it from the Microsoft Store." -ForegroundColor DarkGray
    Write-Host ""
    exit 1
}

$workspace = Get-Content $workspaceFile -Raw | ConvertFrom-Json

# Handle both old format (flat sessions) and new format (groups)
$groups = @()
if ($workspace.PSObject.Properties.Name -contains 'groups') {
    $groups = @($workspace.groups)
} elseif ($workspace.PSObject.Properties.Name -contains 'sessions') {
    # Legacy flat format --treat all sessions as one group
    $groups = @([PSCustomObject]@{
        name     = 'All Sessions'
        tabColor = '#4A9BD9'
        sessions = @($workspace.sessions)
    })
}

if ($groups.Count -eq 0 -or ($groups | ForEach-Object { $_.sessions.Count } | Measure-Object -Sum).Sum -eq 0) {
    Write-Host ""
    Write-Host "  Workspace is empty. Run workspace-snapshot.bat first." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}

# Show snapshot info
$created = [DateTime]::Parse($workspace.created).ToLocalTime()
$age = (Get-Date) - $created
$ageStr = if ($age.TotalHours -lt 1) { "$([int]$age.TotalMinutes)m ago" }
          elseif ($age.TotalHours -lt 24) { "$([int]$age.TotalHours)h ago" }
          else { "$([int]$age.TotalDays)d ago" }

Write-Host ""
Write-Host "  WORKSPACE RESTORE" -ForegroundColor Cyan
Write-Host "  Snapshot: $($created.ToString('yyyy-MM-dd HH:mm')) ($ageStr)" -ForegroundColor DarkGray

if ($age.TotalHours -gt 48) {
    Write-Host "  WARNING: This snapshot is old. Sessions may have stale context." -ForegroundColor Yellow
}

Write-Host ""

# Display groups and sessions
$globalIdx = 0
$groupMap = @{}  # maps display number -> group index
$sessionMap = @{}  # maps display number -> (group index, session index)

for ($gi = 0; $gi -lt $groups.Count; $gi++) {
    $g = $groups[$gi]
    $groupMap[$gi] = $gi
    Write-Host "  Window $($gi+1): " -NoNewline -ForegroundColor White
    Write-Host "$($g.name)" -NoNewline -ForegroundColor Green
    Write-Host " ($($g.tabColor))" -NoNewline -ForegroundColor DarkGray
    Write-Host " --$($g.sessions.Count) tab(s)" -ForegroundColor DarkGray

    for ($si = 0; $si -lt $g.sessions.Count; $si++) {
        $globalIdx++
        $s = $g.sessions[$si]
        $sessionMap[$globalIdx] = @($gi, $si)

        $tabName = if ($s.tabName) { $s.tabName } else {
            $project = Split-Path $s.projectPath -Leaf
            "$project"
        }
        if ($tabName.Length -gt 60) { $tabName = $tabName.Substring(0, 57) + '...' }

        Write-Host "    $globalIdx. " -NoNewline -ForegroundColor DarkGray
        Write-Host "$tabName" -ForegroundColor White
    }
    Write-Host ""
}

# Select what to restore
$selectedGroups = @()
if ($All) {
    $selectedGroups = 0..($groups.Count - 1)
} else {
    Write-Host "  Options:" -ForegroundColor DarkGray
    Write-Host "    Enter    = restore all windows" -ForegroundColor DarkGray
    Write-Host "    w1,w2    = restore specific windows (e.g. w1,w3)" -ForegroundColor DarkGray
    Write-Host "    1,3,5    = restore specific tabs (e.g. 1,3,5)" -ForegroundColor DarkGray
    Write-Host "    n        = cancel" -ForegroundColor DarkGray
    Write-Host ""
    $response = Read-Host "  Choice"

    if ($response -eq '' -or $response -match '^[Yy]') {
        $selectedGroups = 0..($groups.Count - 1)
    } elseif ($response -match '^[Nn]') {
        Write-Host "  Cancelled." -ForegroundColor Yellow
        Write-Host ""
        exit 0
    } elseif ($response -match 'w') {
        # Window selection mode: w1, w2, etc.
        $selectedGroups = @($response -split '[,\s]+' | ForEach-Object {
            $num = 0
            $cleaned = $_ -replace '[wW]', ''
            if ([int]::TryParse($cleaned.Trim(), [ref]$num)) { $num - 1 }
        } | Where-Object { $_ -ge 0 -and $_ -lt $groups.Count } | Select-Object -Unique)
    } else {
        # Individual tab selection: 1, 3, 5, etc.
        # We'll collect selected sessions and group them for opening
        $selectedTabs = @($response -split '[,\s]+' | ForEach-Object {
            $num = 0
            if ([int]::TryParse($_.Trim(), [ref]$num)) { $num }
        } | Where-Object { $sessionMap.ContainsKey($_) } | Select-Object -Unique)

        if ($selectedTabs.Count -eq 0) {
            Write-Host "  No valid selection." -ForegroundColor Yellow
            Write-Host ""
            exit 0
        }

        # Group selected tabs by their original group for proper windowing
        $tabGroups = [ordered]@{}
        foreach ($tabNum in $selectedTabs) {
            $gi, $si = $sessionMap[$tabNum]
            $g = $groups[$gi]
            $gName = $g.name
            if (-not $tabGroups.Contains($gName)) {
                $tabGroups[$gName] = [PSCustomObject]@{
                    name     = $gName
                    tabColor = $g.tabColor
                    sessions = [System.Collections.ArrayList]::new()
                }
            }
            [void]$tabGroups[$gName].sessions.Add($g.sessions[$si])
        }

        # Open each tab group as a window
        $totalTabs = 0
        foreach ($tg in $tabGroups.Values) {
            $wtParts = @()
            $first = $true

            foreach ($s in $tg.sessions) {
                $totalTabs++
                $tabTitle = if ($s.tabName) { $s.tabName } else { Split-Path $s.projectPath -Leaf }
                $tabColor = if ($s.tabColor) { $s.tabColor } else { $tg.tabColor }
                $dir = $s.projectPath
                $id = $s.sessionId

                if (-not $first) {
                    $wtParts += ";"
                    $wtParts += "new-tab"
                }
                $wtParts += "-d"
                $wtParts += "`"$dir`""
                $wtParts += "--title"
                $wtParts += "`"$tabTitle`""
                $wtParts += "--suppressApplicationTitle"
                if ($tabColor) {
                    $wtParts += "--tabColor"
                    $wtParts += "`"$tabColor`""
                }
                $wtParts += "cmd"
                $wtParts += "/k"
                $wtParts += "`"claude --resume $id`""
                $first = $false
            }

            $wtCmd = "wt " + ($wtParts -join ' ')
            cmd /c $wtCmd
            Start-Sleep -Milliseconds 500  # brief pause between windows
        }

        Write-Host "  Opened $totalTabs tab(s) in $($tabGroups.Count) window(s)." -ForegroundColor Green
        Write-Host ""
        exit 0
    }
}

if ($selectedGroups.Count -eq 0) {
    Write-Host "  No valid groups selected." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# Open each selected group as a separate Windows Terminal window
$totalTabs = 0
$totalWindows = 0

foreach ($gi in $selectedGroups) {
    $g = $groups[$gi]
    if ($g.sessions.Count -eq 0) { continue }

    $totalWindows++
    $wtParts = @()
    $first = $true

    foreach ($s in $g.sessions) {
        $totalTabs++
        $tabTitle = if ($s.tabName) { $s.tabName } else { Split-Path $s.projectPath -Leaf }
        $tabColor = if ($s.tabColor) { $s.tabColor } else { $g.tabColor }
        $dir = $s.projectPath
        $id = $s.sessionId

        if (-not $first) {
            $wtParts += ";"
            $wtParts += "new-tab"
        }
        $wtParts += "-d"
        $wtParts += "`"$dir`""
        $wtParts += "--title"
        $wtParts += "`"$tabTitle`""
        $wtParts += "--suppressApplicationTitle"
        if ($tabColor) {
            $wtParts += "--tabColor"
            $wtParts += "`"$tabColor`""
        }
        $wtParts += "cmd"
        $wtParts += "/k"
        $wtParts += "`"claude --resume $id`""
        $first = $false
    }

    $wtCmd = "wt " + ($wtParts -join ' ')

    Write-Host "  Opening window: $($g.name) ($($g.sessions.Count) tabs)..." -ForegroundColor Green
    cmd /c $wtCmd

    # Brief pause between windows so they don't collide
    if ($gi -ne $selectedGroups[-1]) {
        Start-Sleep -Milliseconds 800
    }
}

Write-Host "  Done! Opened $totalTabs tab(s) across $totalWindows window(s)." -ForegroundColor Green
Write-Host ""
