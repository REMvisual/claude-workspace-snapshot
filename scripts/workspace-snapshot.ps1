# workspace-snapshot.ps1
# Captures LIVE Claude Code sessions, tiered by certainty:
#   [OPEN]  uuid confirmed by a running tab process (claude.exe cmdline or happy-coder logs)
#   [OPEN?] an open tab exists but its session is inferred by recency (bare claude.exe)
#   [F]     recent file activity only -- may already be closed
#   [BG]    running but not a terminal tab (happy remote sessions, daemon forks)
# Real Windows Terminal tab titles are shown as ground truth via UIAutomation.
#
# Usage: workspace-snapshot.bat           (default: process detection + 30min file window)
#        workspace-snapshot.bat [minutes]  (custom file activity window, e.g. 60)

param(
    [int]$Minutes = 30
)

$claudeDir = Join-Path $env:USERPROFILE '.claude'
$projectsDir = Join-Path $claudeDir 'projects'
$workspaceFile = Join-Path $claudeDir 'workspace.json'

# --- STEP 1: Detect live session IDs (tiered by certainty) ---

$uuidRe = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

# Snapshot the full process table once
$allProcs = @{}
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
    $allProcs[[uint32]$_.ProcessId] = $_
}

# Does this process live inside a Windows Terminal tab?
function Test-UnderWindowsTerminal {
    param([uint32]$ProcId)
    $cur = $ProcId
    for ($d = 0; $d -lt 12; $d++) {
        if (-not $allProcs.ContainsKey($cur)) { return $false }
        $p = $allProcs[$cur]
        if ($p.Name -eq 'WindowsTerminal.exe') { return $true }
        $cur = [uint32]$p.ParentProcessId
    }
    return $false
}

$confirmedOpen = @{}   # sessionId -> $true : uuid confirmed by a process inside a terminal tab
$confirmedBg   = @{}   # sessionId -> $true : uuid confirmed by a process NOT in a tab (remote/daemon)
$bareOpenCount = 0     # interactive claude.exe tabs whose session id is unknowable

# Method A: claude.exe processes — extract uuid from --session-id / --resume
foreach ($p in $allProcs.Values) {
    if ($p.Name -ne 'claude.exe' -or -not $p.CommandLine) { continue }
    if ($p.CommandLine -match 'daemon run|--bg-pty-host') { continue }   # background infra
    $sid = $null
    if ($p.CommandLine -match "--session-id\s+($uuidRe)") { $sid = $Matches[1] }
    elseif ($p.CommandLine -match "--resume\s+($uuidRe)") { $sid = $Matches[1] }
    $inTab = Test-UnderWindowsTerminal ([uint32]$p.ProcessId)
    if ($sid) {
        if ($inTab) { $confirmedOpen[$sid] = $true } else { $confirmedBg[$sid] = $true }
    } elseif ($inTab) {
        $bareOpenCount++
    }
}

# Method H: happy-coder wrapped sessions — running happy node processes log their
# Claude session uuid to ~/.happy/logs/*-pid-<pid>.log (last uuid in the log wins)
$happyLogsDir = Join-Path $env:USERPROFILE '.happy\logs'
if (Test-Path $happyLogsDir) {
    foreach ($p in $allProcs.Values) {
        if ($p.Name -ne 'node.exe' -or -not $p.CommandLine) { continue }
        if ($p.CommandLine -notmatch 'happy-coder') { continue }
        $log = Get-ChildItem -Path $happyLogsDir -Filter "*-pid-$($p.ProcessId).log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $log) { continue }
        $sid = $null
        Select-String -Path $log.FullName -Pattern "`"sessionId`":\s*`"($uuidRe)`"" -ErrorAction SilentlyContinue |
            ForEach-Object { $sid = $_.Matches[0].Groups[1].Value }
        if (-not $sid) { continue }
        if (Test-UnderWindowsTerminal ([uint32]$p.ProcessId)) {
            $confirmedOpen[$sid] = $true
        } elseif (-not $confirmedOpen.ContainsKey($sid)) {
            $confirmedBg[$sid] = $true
        }
    }
}

# Ground truth for display: real Windows Terminal tab titles via UIAutomation
$openTabTitles = @()
try {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
    $uiaRoot = [System.Windows.Automation.AutomationElement]::RootElement
    $winCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'CASCADIA_HOSTING_WINDOW_CLASS')
    $tabCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::TabItem)
    foreach ($w in $uiaRoot.FindAll([System.Windows.Automation.TreeScope]::Children, $winCond)) {
        foreach ($t in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCond)) {
            if ($t.Current.Name) { $openTabTitles += $t.Current.Name }
        }
    }
} catch {}

# Method B: .jsonl files modified recently (catches sessions invisible to A/H)
$recentCutoff = (Get-Date).AddMinutes(-$Minutes)
$recentIds = @()
Get-ChildItem -Path $projectsDir -Filter '*.jsonl' -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -gt $recentCutoff -and $_.BaseName -match '^[0-9a-f]{8}-' } |
    ForEach-Object { $recentIds += $_.BaseName }

# Combine and deduplicate
$processIds = @($confirmedOpen.Keys) + @($confirmedBg.Keys)
$liveIds = @($processIds + $recentIds | Select-Object -Unique)

# --- STEP 1b: History recovery fallback (only when no live sessions) ---
# Triggered after a reboot/blackout where every Claude session was closed.
# Live sessions always win — this branch is only reachable when $liveIds is empty.

$historyMode = $false
$historySubtitle = ''

if ($liveIds.Count -eq 0) {
    Write-Host ""
    Write-Host "  No live Claude sessions detected." -ForegroundColor Yellow
    Write-Host "  (checked running processes + files modified in last $Minutes min)" -ForegroundColor DarkGray
    Write-Host ""

    # Tip if a recent workspace.json from before the last boot already exists
    try {
        $lastBootForTip = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        if (Test-Path $workspaceFile) {
            $wsMtime = (Get-Item $workspaceFile).LastWriteTime
            if ($wsMtime -lt $lastBootForTip) {
                Write-Host "  Tip: workspace.json exists from $($wsMtime.ToString('MMM dd HH:mm')) -- workspace-restore.bat may already have what you need." -ForegroundColor DarkGray
                Write-Host ""
            }
        }
    } catch {}

    $histResp = Read-Host "  Look at recent history? [Y/n]"
    if ($histResp -match '^[Nn]') {
        Write-Host ""
        exit 0
    }

    # Determine candidate session IDs from history.
    try {
        $lastBoot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
    } catch {
        $lastBoot = $null
    }

    $bootStaleDays = if ($lastBoot) { ((Get-Date) - $lastBoot).TotalDays } else { 999 }
    $historyIds = @()

    if ($lastBoot -and $bootStaleDays -le 7) {
        # Primary: files modified in the 2 hours before last boot
        $windowStart = $lastBoot.AddHours(-2)
        $windowEnd   = $lastBoot
        $historyIds = @(Get-ChildItem -Path $projectsDir -Filter '*.jsonl' -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $_.BaseName -match '^[0-9a-f]{8}-' -and
                $_.LastWriteTime -ge $windowStart -and
                $_.LastWriteTime -le $windowEnd
            } |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object { $_.BaseName })

        if ($historyIds.Count -gt 0) {
            $historySubtitle = "$($historyIds.Count) sessions from before last boot ($($lastBoot.ToString('MMM dd HH:mm')) -- 2h window)"
        }
    }

    if ($historyIds.Count -eq 0) {
        # Fallback: top 20 most recently modified within last 30 days
        $thirtyDaysAgo = (Get-Date).AddDays(-30)
        $historyIds = @(Get-ChildItem -Path $projectsDir -Filter '*.jsonl' -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $_.BaseName -match '^[0-9a-f]{8}-' -and
                $_.LastWriteTime -ge $thirtyDaysAgo
            } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 20 |
            ForEach-Object { $_.BaseName })

        if ($historyIds.Count -gt 0) {
            if (-not $lastBoot) {
                $historySubtitle = "$($historyIds.Count) most recently active sessions (fallback -- boot time unavailable)"
            } elseif ($bootStaleDays -gt 7) {
                $historySubtitle = "$($historyIds.Count) most recently active sessions (fallback -- last boot was $([int]$bootStaleDays) days ago)"
            } else {
                $historySubtitle = "$($historyIds.Count) most recently active sessions (fallback -- no sessions found near boot time)"
            }
        }
    }

    if ($historyIds.Count -eq 0) {
        Write-Host ""
        Write-Host "  No historical sessions found in $projectsDir." -ForegroundColor Yellow
        Write-Host ""
        exit 0
    }

    $liveIds = $historyIds
    $historyMode = $true
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

# Deterministic color palette -- each project gets a stable color based on its name
$colorPalette = @(
    '#4A9BD9','#D94A4A','#9B59B6','#E67E22','#2ECC71',
    '#1ABC9C','#F1C40F','#E74C3C','#3498DB','#E91E63',
    '#8E44AD','#D35400','#27AE60','#2980B9','#C0392B',
    '#16A085','#F39C12','#7D3C98','#2471A3','#CB4335'
)

function Get-ProjectColor {
    param([string]$Name)
    [int]$hash = 5381
    foreach ($c in $Name.ToCharArray()) {
        $hash = (($hash * 33) + [int]$c) -band 0x7FFFFFFF
    }
    $idx = $hash % $colorPalette.Count
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
                    $candidate = $null
                    if ($content -is [string]) {
                        $candidate = $content
                    } elseif ($content -is [array]) {
                        $textBlock = $content | Where-Object { $_.type -eq 'text' } | Select-Object -First 1
                        if ($textBlock) { $candidate = $textBlock.text }
                    }
                    # Skip caveat headers and slash-command records — not real prompts, keep looking
                    if ($candidate -and $candidate -notmatch '^\s*(<local-command-caveat>|<command-name>|<command-message>|Caveat: The messages below)') {
                        $firstPrompt = $candidate
                        if ($obj.cwd) { $cwd = $obj.cwd }
                        if ($obj.gitBranch) { $gitBranch = $obj.gitBranch }
                        break
                    }
                }
            } catch {}
        }
        $reader.Close()
    } catch {}

    if ($isSidechain -or -not $firstPrompt -or -not $cwd) { continue }

    # Claude Code persists its live tab title as ai-title records — the LAST one is
    # what the terminal tab actually shows. Best possible display name.
    $aiTitle = $null
    Select-String -Path $jsonlFile.FullName -Pattern '"type":"ai-title","aiTitle":"([^"]+)"' -ErrorAction SilentlyContinue |
        ForEach-Object { $aiTitle = $_.Matches[0].Groups[1].Value }

    # Display name precedence: live tab title > indexed summary > first prompt
    # (indexed summaries can also be a stale resume-caveat header)
    $summary = if ($aiTitle) {
        $aiTitle
    } elseif ($summaryLookup.ContainsKey($sid) -and $summaryLookup[$sid] -notmatch '^\s*(<local-command-caveat>|<command-name>|Caveat: The messages below)') {
        $summaryLookup[$sid]
    } else {
        $firstPrompt
    }
    $tabName = $summary -replace '\s+', ' ' -replace '<[^>]+>', ''
    $tabName = $tabName.Trim()
    if ($tabName.Length -gt 40) { $tabName = $tabName.Substring(0, 37) + '...' }

    $project = Split-Path $cwd -Leaf

    $tabColor = Get-ProjectColor $project

    if ($historyMode) {
        $source = 'history'; $tier = 'recent'
    } elseif ($confirmedOpen.ContainsKey($sid)) {
        $source = 'process'; $tier = 'open'
    } elseif ($confirmedBg.ContainsKey($sid)) {
        $source = 'process'; $tier = 'background'
    } else {
        $source = 'file'; $tier = 'recent'
    }

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
        tier        = $tier
    })
}

# Promote: we counted bare interactive claude.exe tabs (no uuid in cmdline) — the
# N most recently active unconfirmed sessions are most likely those open tabs
if (-not $historyMode -and $bareOpenCount -gt 0) {
    @($sessions | Where-Object { $_.tier -eq 'recent' } |
        Sort-Object @{Expression={[DateTime]::Parse($_.modified)}; Descending=$true} |
        Select-Object -First $bareOpenCount) |
        ForEach-Object { $_.tier = 'maybe' }
}

# Sort by tier (open > maybe > recent > background), then project group, then newest first
$tierOrder = @{ open = 0; maybe = 1; recent = 2; background = 3 }
$sessions = @($sessions | Sort-Object @{Expression={$tierOrder[$_.tier]}}, @{Expression={$_.group}}, @{Expression={[DateTime]::Parse($_.modified)}; Descending=$true})

if ($sessions.Count -eq 0) {
    Write-Host ""
    Write-Host "  No valid live sessions found." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# --- STEP 3: Display ---

$openCount   = @($sessions | Where-Object { $_.tier -eq 'open' }).Count
$maybeCount  = @($sessions | Where-Object { $_.tier -eq 'maybe' }).Count
$recentCount = @($sessions | Where-Object { $_.tier -eq 'recent' }).Count
$bgCount     = @($sessions | Where-Object { $_.tier -eq 'background' }).Count

Write-Host ""
if ($historyMode) {
    Write-Host "  WORKSPACE SNAPSHOT (history recovery)" -ForegroundColor Yellow
    Write-Host "  $historySubtitle" -ForegroundColor DarkGray
} else {
    Write-Host "  WORKSPACE SNAPSHOT (live detection)" -ForegroundColor Cyan
    if ($openTabTitles.Count -gt 0) {
        $titleList = ($openTabTitles | ForEach-Object { if ($_.Length -gt 25) { $_.Substring(0, 22) + '...' } else { $_ } }) -join ', '
        Write-Host "  Open terminal tabs ($($openTabTitles.Count)): " -NoNewline -ForegroundColor DarkGray
        Write-Host $titleList -ForegroundColor Cyan
    }
    $parts = @()
    if ($openCount)   { $parts += "$openCount open for sure" }
    if ($maybeCount)  { $parts += "$maybeCount likely open" }
    if ($recentCount) { $parts += "$recentCount recent-only" }
    if ($bgCount)     { $parts += "$bgCount background" }
    Write-Host "  $($sessions.Count) sessions: $($parts -join ', ')" -ForegroundColor DarkGray
}

$tierBanners = @{
    open       = @{ text = '=== OPEN (confirmed by running process) ==='; color = 'Green' }
    maybe      = @{ text = '=== LIKELY OPEN (open tab detected, session inferred by recency) ==='; color = 'Yellow' }
    recent     = @{ text = '=== RECENT (file activity only -- may be closed) ==='; color = 'DarkGray' }
    background = @{ text = '=== BACKGROUND / REMOTE (running, not a terminal tab) ==='; color = 'DarkCyan' }
}

$currentGroup = ''
$currentTier = ''
for ($i = 0; $i -lt $sessions.Count; $i++) {
    $s = $sessions[$i]
    if (-not $historyMode -and $s.tier -ne $currentTier) {
        $currentTier = $s.tier
        $currentGroup = ''
        $banner = $tierBanners[$currentTier]
        Write-Host ""
        Write-Host "  $($banner.text)" -ForegroundColor $banner.color
    }
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
    if ($historyMode) {
        $tierTag = ' [H]'; $tierColor = 'DarkGray'
    } else {
        switch ($s.tier) {
            'open'       { $tierTag = ' [OPEN]';  $tierColor = 'Green' }
            'maybe'      { $tierTag = ' [OPEN?]'; $tierColor = 'Yellow' }
            'background' { $tierTag = ' [BG]';    $tierColor = 'DarkCyan' }
            default      { $tierTag = ' [F]';     $tierColor = 'DarkGray' }
        }
    }

    Write-Host "  $($i+1). " -NoNewline -ForegroundColor White
    Write-Host "$summary" -NoNewline
    Write-Host "$branch" -NoNewline -ForegroundColor Yellow
    Write-Host "$tierTag" -NoNewline -ForegroundColor $tierColor
    Write-Host " $time" -ForegroundColor DarkGray
}

Write-Host ""

# Ask user which sessions to save (default: all; 'o' = open + likely-open tabs only)
$response = Read-Host "  Save all? [Y/n/o=open only] or enter numbers (e.g. 1,3,5)"

$selected = @()
if ($response -eq '' -or $response -match '^[Yy]') {
    $selected = 0..($sessions.Count - 1)
} elseif ($response -match '^[Oo]') {
    $selected = @(0..($sessions.Count - 1) | Where-Object { $sessions[$_].tier -in @('open', 'maybe') })
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
