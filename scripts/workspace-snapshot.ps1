# workspace-snapshot.ps1
# Captures LIVE Claude Code sessions by detecting running processes + recent file activity.
# Only snapshots tabs that are actually open, not stale sessions.
#
# Usage: workspace-snapshot.bat           (default: process detection + 30min file window)
#        workspace-snapshot.bat [minutes]  (custom file activity window, e.g. 60)

param(
    [int]$Minutes = 30
)

$claudeDir = Join-Path $env:USERPROFILE '.claude'
$projectsDir = Join-Path $claudeDir 'projects'
$workspaceFile = Join-Path $claudeDir 'workspace.json'

# --- STEP 1: Detect live session IDs ---

# Method A: Running claude.exe processes with --resume <id>
$processIds = @()
Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.CommandLine -match 'resume\s+([0-9a-f-]{36})') {
        $processIds += $Matches[1]
    }
}

# Method B: .jsonl files modified recently (catches IDE/SDK sessions)
$recentCutoff = (Get-Date).AddMinutes(-$Minutes)
$recentIds = @()
Get-ChildItem -Path $projectsDir -Filter '*.jsonl' -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -gt $recentCutoff -and $_.BaseName -match '^[0-9a-f]{8}-' } |
    ForEach-Object { $recentIds += $_.BaseName }

# Combine and deduplicate
$liveIds = @($processIds + $recentIds | Select-Object -Unique)

if ($liveIds.Count -eq 0) {
    Write-Host ""
    Write-Host "  No live Claude sessions detected." -ForegroundColor Yellow
    Write-Host "  (checked running processes + files modified in last $Minutes min)" -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

# --- STEP 2: Build session metadata from .jsonl files ---

# Summaries from sessions-index.json (if available)
$summaryLookup = @{}
Get-ChildItem -Path $projectsDir -Filter 'sessions-index.json' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $index = Get-Content $_.FullName -Raw | ConvertFrom-Json
        foreach ($entry in $index.entries) {
            if ($entry.summary) { $summaryLookup[$entry.sessionId] = $entry.summary }
        }
    } catch {}
}

# Deterministic color palette — each project gets a stable color based on its name
$colorPalette = @(
    '#4A9BD9','#D94A4A','#9B59B6','#E67E22','#2ECC71',
    '#1ABC9C','#F1C40F','#E74C3C','#3498DB','#E91E63',
    '#8E44AD','#D35400','#27AE60','#2980B9','#C0392B',
    '#16A085','#F39C12','#7D3C98','#2471A3','#CB4335'
)

function Get-ProjectColor {
    param([string]$Name)
    $hash = 5381
    foreach ($c in $Name.ToCharArray()) {
        $hash = (($hash -shl 5) + $hash) + [int]$c
    }
    $idx = [Math]::Abs($hash) % $colorPalette.Count
    return $colorPalette[$idx]
}

$sessions = [System.Collections.ArrayList]::new()

# Find and read each live session's .jsonl file
foreach ($sid in $liveIds) {
    # Find the .jsonl file across all project dirs
    $jsonlFile = Get-ChildItem -Path $projectsDir -Filter "$sid.jsonl" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $jsonlFile) { continue }

    $firstPrompt = $null
    $cwd = $null
    $gitBranch = ''
    $isSidechain = $false
    $slug = $null

    try {
        $reader = [System.IO.StreamReader]::new($jsonlFile.FullName)
        $lineCount = 0
        while ($null -ne ($line = $reader.ReadLine()) -and $lineCount -lt 100) {
            $lineCount++
            try {
                $obj = $line | ConvertFrom-Json -ErrorAction Stop

                if ($obj.isSidechain -eq $true) { $isSidechain = $true; break }
                if (-not $cwd -and $obj.cwd) { $cwd = $obj.cwd }
                if (-not $gitBranch -and $obj.gitBranch) { $gitBranch = $obj.gitBranch }
                if (-not $slug -and $obj.slug) { $slug = $obj.slug }

                if ($obj.type -eq 'user' -and -not $firstPrompt -and $obj.message -and $obj.message.content) {
                    $content = $obj.message.content
                    if ($content -is [string]) {
                        $firstPrompt = $content
                    } elseif ($content -is [array]) {
                        $textBlock = $content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1
                        if ($textBlock) { $firstPrompt = $textBlock.text }
                    }
                    if ($obj.cwd) { $cwd = $obj.cwd }
                    if ($obj.gitBranch) { $gitBranch = $obj.gitBranch }
                    break
                }
            } catch {}
        }
        $reader.Close()
    } catch {}

    if ($isSidechain -or -not $firstPrompt -or -not $cwd) { continue }

    # Summary and tab name
    $summary = if ($summaryLookup.ContainsKey($sid)) { $summaryLookup[$sid] } else { $firstPrompt }
    $tabName = $summary -replace '\s+', ' ' -replace '<[^>]+>', ''
    $tabName = $tabName.Trim()
    if ($tabName.Length -gt 40) { $tabName = $tabName.Substring(0, 37) + '...' }

    $project = Split-Path $cwd -Leaf

    $tabColor = Get-ProjectColor $project

    $source = if ($processIds -contains $sid) { 'process' } else { 'file' }

    [void]$sessions.Add([PSCustomObject]@{
        sessionId   = $sid
        projectPath = $cwd
        project     = $project
        summary     = $summary
        tabName     = "$project`: $tabName"
        tabColor    = $tabColor
        firstPrompt = if ($firstPrompt.Length -gt 80) { $firstPrompt.Substring(0, 77) + '...' } else { $firstPrompt }
        modified    = $jsonlFile.LastWriteTime.ToString('o')
        gitBranch   = $gitBranch
        slug        = $slug
        group       = $project
        source      = $source
    })
}

# Sort by project group, then newest first within each group
$sessions = @($sessions | Sort-Object @{Expression={$_.group}}, @{Expression={[DateTime]::Parse($_.modified)}; Descending=$true})

if ($sessions.Count -eq 0) {
    Write-Host ""
    Write-Host "  No valid live sessions found." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# --- STEP 3: Display ---

$procCount = @($sessions | Where-Object { $_.source -eq 'process' }).Count
$fileCount = @($sessions | Where-Object { $_.source -eq 'file' }).Count

Write-Host ""
Write-Host "  WORKSPACE SNAPSHOT (live detection)" -ForegroundColor Cyan
Write-Host "  $($sessions.Count) live sessions ($procCount from processes, $fileCount from file activity)" -ForegroundColor DarkGray
Write-Host ""

$currentGroup = ''
for ($i = 0; $i -lt $sessions.Count; $i++) {
    $s = $sessions[$i]
    if ($s.group -ne $currentGroup) {
        $currentGroup = $s.group
        Write-Host "  --- $currentGroup " -NoNewline -ForegroundColor Green
        Write-Host "($($s.tabColor)) " -NoNewline -ForegroundColor DarkGray
        Write-Host "---" -ForegroundColor Green
    }
    $summary = $s.summary -replace '<[^>]+>', '' -replace '\s+', ' '
    if ($summary.Length -gt 55) { $summary = $summary.Substring(0, 52) + '...' }
    $time = [DateTime]::Parse($s.modified).ToLocalTime().ToString('MMM dd HH:mm')
    $branch = if ($s.gitBranch -and $s.gitBranch -ne '' -and $s.gitBranch -ne 'master' -and $s.gitBranch -ne 'main') { " [$($s.gitBranch)]" } else { '' }
    $srcTag = if ($s.source -eq 'process') { ' [P]' } else { ' [F]' }

    Write-Host "  $($i+1). " -NoNewline -ForegroundColor White
    Write-Host "$summary" -NoNewline
    Write-Host "$branch" -NoNewline -ForegroundColor Yellow
    Write-Host "$srcTag" -NoNewline -ForegroundColor DarkGray
    Write-Host " $time" -ForegroundColor DarkGray
}

Write-Host ""

# Ask user which sessions to save (default: all)
$response = Read-Host "  Save all? [Y/n] or enter numbers (e.g. 1,3,5)"

$selected = @()
if ($response -eq '' -or $response -match '^[Yy]') {
    $selected = 0..($sessions.Count - 1)
} elseif ($response -match '^[Nn]') {
    Write-Host "  Cancelled." -ForegroundColor Yellow
    Write-Host ""
    exit 0
} else {
    $selected = @($response -split '[,\s]+' | ForEach-Object {
        $num = 0
        if ([int]::TryParse($_.Trim(), [ref]$num)) { $num - 1 }
    } | Where-Object { $_ -ge 0 -and $_ -lt $sessions.Count } | Select-Object -Unique)
}

if ($selected.Count -eq 0) {
    Write-Host "  No valid sessions selected." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# --- STEP 4: Save workspace with groups ---

$selectedSessions = @($selected | ForEach-Object { $sessions[$_] })

$groups = [ordered]@{}
foreach ($s in $selectedSessions) {
    $g = $s.group
    if (-not $groups.Contains($g)) {
        $groups[$g] = [System.Collections.ArrayList]::new()
    }
    [void]$groups[$g].Add($s)
}

$groupList = @($groups.GetEnumerator() | ForEach-Object {
    [PSCustomObject]@{
        name     = $_.Key
        tabColor = $_.Value[0].tabColor
        sessions = @($_.Value)
    }
})

$workspace = [PSCustomObject]@{
    created = (Get-Date).ToString('o')
    groups  = $groupList
}

$workspace | ConvertTo-Json -Depth 5 | Set-Content $workspaceFile -Encoding UTF8

$tabCount = ($groupList | ForEach-Object { $_.sessions.Count } | Measure-Object -Sum).Sum
Write-Host "  Saved $tabCount session(s) in $($groupList.Count) window group(s)." -ForegroundColor Green
Write-Host "  Run workspace-restore.bat to reopen after restart." -ForegroundColor DarkGray
Write-Host ""
