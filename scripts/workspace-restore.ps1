# workspace-restore.ps1
# Reopens Claude Code sessions in Windows Terminal tabs from a workspace snapshot.
# Each group becomes a separate Windows Terminal window (forced via `wt -w new`).
# Tab names and colors are preserved from the snapshot.
#
# Every entry is validated before anything opens (workspace.json is user-editable):
# session ids must be UUIDs, colors must be #RRGGBB, dead project dirs fall back to
# the user profile, and sessions whose .jsonl vanished are flagged [missing].
#
# Usage: workspace-restore.bat                (interactive - pick which groups/sessions)
#        workspace-restore.bat --all          (restore everything without asking)
#        workspace-restore.bat --dry-run      (print the wt commands instead of running them)
#        workspace-restore.bat --file <path>  (restore from an alternate snapshot, e.g. a backup)

param(
    [switch]$All,
    [switch]$DryRun,
    [string]$Path
)

function Show-RestoreUsage {
    Write-Host ""
    Write-Host "  Usage: workspace-restore.bat [--all] [--dry-run] [--file <path>]" -ForegroundColor Yellow
    Write-Host ""
}

# GNU-style flags that don't prefix-match a param name land in $args -- parse them here.
$badArgs = @()
for ($ai = 0; $ai -lt $args.Count; $ai++) {
    $a = "$($args[$ai])"
    if ($a -match '^--?all$') { $All = $true }
    elseif ($a -match '^--?dry-?run$') { $DryRun = $true }
    elseif ($a -match '^--?(file|path)$' -and $ai + 1 -lt $args.Count) { $Path = "$($args[$ai + 1])"; $ai++ }
    else { $badArgs += $a }
}
if ($badArgs.Count -gt 0) {
    Write-Host ""
    Write-Host "  Unknown argument(s): $($badArgs -join ', ')" -ForegroundColor Red
    Show-RestoreUsage
    exit 1
}

$claudeDir = Join-Path $env:USERPROFILE '.claude'
$projectsDir = Join-Path $claudeDir 'projects'
$workspaceFile = Join-Path $claudeDir 'workspace.json'
if ($Path) {
    $workspaceFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

$uuidRe = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$defaultColor = '#4A9BD9'

# Titles get spliced into a cmd /c + wt.exe command line -- keep them inert even
# if the user hand-edited workspace.json.
function Get-SafeTabName {
    param([string]$Name)
    if (-not $Name) { return '' }
    $n = $Name -replace '[\x00-\x1F"<>|&^%]', '' -replace ';', ','
    return ($n -replace '\s+', ' ').Trim()
}

# Resume verbs come from this table only -- nothing from workspace.json is ever
# interpolated into the command line as a program name or flag.
$script:agentSpecs = @{
    claude = [pscustomobject]@{ exe = 'claude'; verb = '--resume' }
    codex  = [pscustomobject]@{ exe = 'codex';  verb = 'resume' }
}
function Get-ResumeCommand {
    param([string]$Agent, [string]$SessionId)
    $a = "$Agent".Trim().ToLower()
    if (-not $script:agentSpecs.ContainsKey($a)) { return $null }
    $spec = $script:agentSpecs[$a]
    return "$($spec.exe) $($spec.verb) $SessionId"
}

# Test seam: dot-source with WSS_LOAD_ONLY=1 to get the functions without running the tool.
if ($env:WSS_LOAD_ONLY -eq '1') { return }

# Check workspace exists
if (-not (Test-Path $workspaceFile)) {
    Write-Host ""
    Write-Host "  No workspace file found at $workspaceFile" -ForegroundColor Yellow
    Write-Host "  Run workspace-snapshot.bat first to capture your sessions." -ForegroundColor DarkGray
    Write-Host ""
    exit 1
}

# Check wt.exe exists (a dry run is still useful without it)
$wt = Get-Command wt -ErrorAction SilentlyContinue
if (-not $wt -and -not $DryRun) {
    Write-Host ""
    Write-Host "  Windows Terminal (wt.exe) not found." -ForegroundColor Red
    Write-Host "  Install it from the Microsoft Store." -ForegroundColor DarkGray
    Write-Host ""
    exit 1
}

try {
    $workspace = Get-Content $workspaceFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Host ""
    Write-Host "  Could not parse $workspaceFile -- $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    exit 1
}

# Handle both old format (flat sessions) and new format (groups)
$rawGroups = @()
if ($workspace.PSObject.Properties.Name -contains 'groups') {
    $rawGroups = @($workspace.groups)
} elseif ($workspace.PSObject.Properties.Name -contains 'sessions') {
    # Legacy flat format -- treat all sessions as one group
    $rawGroups = @([PSCustomObject]@{
        name     = 'All Sessions'
        tabColor = $defaultColor
        sessions = @($workspace.sessions)
    })
}

# Which session .jsonl files still exist on disk? (one scan, used to flag [missing])
$existingIds = @{}
if (Test-Path $projectsDir) {
    Get-ChildItem -Path $projectsDir -Filter '*.jsonl' -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { $existingIds[$_.BaseName] = $true }
}

# Codex rollouts are rollout-<ts>-<uuid>.jsonl, so BaseName never equals the id --
# extract the uuid suffix instead of matching the whole file name.
$existingCodexIds = @{}
$codexSessionsDir = Join-Path $env:USERPROFILE '.codex\sessions'
if (Test-Path $codexSessionsDir) {
    Get-ChildItem -Path $codexSessionsDir -Filter 'rollout-*.jsonl' -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.BaseName -match "([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$") { $existingCodexIds[$Matches[1]] = $true } }
}

# --- Validate and normalize every entry before anything opens ---
$warnings = @()
$groups = @()
foreach ($g in $rawGroups) {
    $gName = if ($g.name) { "$($g.name)" } else { 'Sessions' }
    $gColor = if ("$($g.tabColor)" -match '^#[0-9A-Fa-f]{6}$') { "$($g.tabColor)" } else { $defaultColor }

    $normSessions = [System.Collections.ArrayList]::new()
    foreach ($s in @($g.sessions)) {
        if (-not $s) { continue }
        $sid = "$($s.sessionId)".Trim().ToLower()
        if ($sid -notmatch $uuidRe) {
            $warnings += "Skipped entry in '$gName': sessionId '$sid' is not a valid session UUID."
            continue
        }

        # No agent field means a pre-Codex snapshot -- treat as claude for backwards
        # compatibility. Never echo the raw agent value: it comes straight from a
        # user-editable file and must not reach the console or a command line.
        $agent = if ($s.agent) { "$($s.agent)".Trim().ToLower() } else { 'claude' }
        if (-not $script:agentSpecs.ContainsKey($agent)) {
            $warnings += "Skipped entry in '$gName': unrecognized agent for $sid."
            continue
        }

        $dir = "$($s.projectPath)"
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) {
            $warnings += "Project dir missing for '$sid' ($dir) -- tab will open in $env:USERPROFILE."
            $dir = $env:USERPROFILE
        }

        $title = Get-SafeTabName "$($s.tabName)"
        if (-not $title) { $title = Get-SafeTabName (Split-Path $dir -Leaf) }
        if (-not $title) { $title = 'claude' }
        if ($title.Length -gt 60) { $title = $title.Substring(0, 57) + '...' }

        $color = if ("$($s.tabColor)" -match '^#[0-9A-Fa-f]{6}$') { "$($s.tabColor)" } else { $gColor }

        $missing = if ($agent -eq 'codex') { -not $existingCodexIds.ContainsKey($sid) } else { -not $existingIds.ContainsKey($sid) }

        [void]$normSessions.Add([PSCustomObject]@{
            sessionId = $sid
            agent     = $agent
            dir       = $dir
            title     = $title
            color     = $color
            missing   = $missing
        })
    }
    if ($normSessions.Count -gt 0) {
        $groups += [PSCustomObject]@{
            name     = $gName
            tabColor = $gColor
            sessions = @($normSessions)
        }
    }
}

# An agent's CLI missing means every one of its restored tabs would die on launch --
# say so once per agent actually referenced by the loaded snapshot, upfront.
$referencedAgents = @($groups.sessions.agent | Select-Object -Unique)
foreach ($a in $referencedAgents) {
    $spec = $script:agentSpecs[$a]
    if ($spec -and -not (Get-Command $spec.exe -ErrorAction SilentlyContinue)) {
        Write-Host ""
        Write-Host "  WARNING: '$($spec.exe)' was not found on PATH. Tabs will open but resume will fail." -ForegroundColor Yellow
    }
}

if ($groups.Count -eq 0) {
    Write-Host ""
    Write-Host "  Workspace has no restorable sessions. Run workspace-snapshot.bat first." -ForegroundColor Yellow
    foreach ($w in $warnings) { Write-Host "  ! $w" -ForegroundColor Yellow }
    Write-Host ""
    exit 1
}

# Builds and runs (or prints, for --dry-run) one `wt` invocation per group.
function Open-WorkspaceWindows {
    param([array]$WindowGroups)
    $script:totalTabs = 0
    $script:totalWindows = 0
    for ($wi = 0; $wi -lt $WindowGroups.Count; $wi++) {
        $g = $WindowGroups[$wi]
        if ($g.sessions.Count -eq 0) { continue }
        $script:totalWindows++

        # -w new: force a fresh window per group even if the user's Windows Terminal
        # windowingBehavior would otherwise glue everything into one window
        $wtParts = @('-w', 'new')
        $first = $true
        foreach ($s in $g.sessions) {
            $script:totalTabs++
            if (-not $first) {
                $wtParts += ";"
                $wtParts += "new-tab"
            }
            $wtParts += "-d"
            $wtParts += "`"$($s.dir)`""
            $wtParts += "--title"
            $wtParts += "`"$($s.title)`""
            $wtParts += "--suppressApplicationTitle"
            if ($s.color) {
                $wtParts += "--tabColor"
                $wtParts += "`"$($s.color)`""
            }
            $wtParts += "cmd"
            $wtParts += "/k"
            $wtParts += "`"$(Get-ResumeCommand -Agent $s.agent -SessionId $s.sessionId)`""
            $first = $false
        }

        $wtCmd = "wt " + ($wtParts -join ' ')
        if ($DryRun) {
            Write-Host "  [dry-run] $wtCmd" -ForegroundColor DarkGray
        } else {
            Write-Host "  Opening window: $($g.name) ($($g.sessions.Count) tabs)..." -ForegroundColor Green
            cmd /c $wtCmd
            # Brief pause between windows so they don't collide
            if ($wi -lt $WindowGroups.Count - 1) {
                Start-Sleep -Milliseconds 800
            }
        }
    }
}

# Show snapshot info
$created = $null
try { $created = [DateTime]::Parse($workspace.created).ToLocalTime() } catch {}

Write-Host ""
Write-Host "  WORKSPACE RESTORE" -ForegroundColor Cyan
if ($created) {
    $age = (Get-Date) - $created
    $ageStr = if ($age.TotalHours -lt 1) { "$([int]$age.TotalMinutes)m ago" }
              elseif ($age.TotalHours -lt 24) { "$([int]$age.TotalHours)h ago" }
              else { "$([int]$age.TotalDays)d ago" }
    Write-Host "  Snapshot: $($created.ToString('yyyy-MM-dd HH:mm')) ($ageStr)" -ForegroundColor DarkGray
    if ($age.TotalHours -gt 48) {
        Write-Host "  WARNING: This snapshot is old. Sessions may have stale context." -ForegroundColor Yellow
    }
}
if ($DryRun) {
    Write-Host "  DRY RUN: commands will be printed, nothing will open." -ForegroundColor Yellow
}
foreach ($w in $warnings) { Write-Host "  ! $w" -ForegroundColor Yellow }

Write-Host ""

# Display groups and sessions
$globalIdx = 0
$sessionMap = @{}  # maps display number -> (group index, session index)

for ($gi = 0; $gi -lt $groups.Count; $gi++) {
    $g = $groups[$gi]
    Write-Host "  Window $($gi+1): " -NoNewline -ForegroundColor White
    Write-Host "$($g.name)" -NoNewline -ForegroundColor Green
    Write-Host " ($($g.tabColor))" -NoNewline -ForegroundColor DarkGray
    Write-Host " -- $($g.sessions.Count) tab(s)" -ForegroundColor DarkGray

    for ($si = 0; $si -lt $g.sessions.Count; $si++) {
        $globalIdx++
        $s = $g.sessions[$si]
        $sessionMap[$globalIdx] = @($gi, $si)

        Write-Host "    $globalIdx. " -NoNewline -ForegroundColor DarkGray
        Write-Host "[$($s.agent)] " -NoNewline -ForegroundColor DarkGray
        Write-Host "$($s.title)" -NoNewline -ForegroundColor White
        if ($s.missing) {
            Write-Host " [missing]" -NoNewline -ForegroundColor Red
        }
        Write-Host ""
    }
    Write-Host ""
}

if (@($groups.sessions | Where-Object { $_.missing }).Count -gt 0) {
    Write-Host "  [missing] = session file no longer exists; the tab will still open in the" -ForegroundColor DarkGray
    Write-Host "  right directory but 'claude --resume' will report the session as gone." -ForegroundColor DarkGray
    Write-Host ""
}

# Select what to restore
$windowGroups = @()
if ($All) {
    $windowGroups = @($groups)
} else {
    Write-Host "  Options:" -ForegroundColor DarkGray
    Write-Host "    Enter    = restore all windows" -ForegroundColor DarkGray
    Write-Host "    w1,w2    = restore specific windows (e.g. w1,w3)" -ForegroundColor DarkGray
    Write-Host "    1,3,5    = restore specific tabs (e.g. 1,3,5)" -ForegroundColor DarkGray
    Write-Host "    n        = cancel" -ForegroundColor DarkGray
    Write-Host ""
    $response = Read-Host "  Choice"

    if ($response -eq '' -or $response -match '^[Yy]') {
        $windowGroups = @($groups)
    } elseif ($response -match '^[Nn]') {
        Write-Host "  Cancelled." -ForegroundColor Yellow
        Write-Host ""
        exit 0
    } elseif ($response -match '(?i)w\s*\d') {
        # Window selection mode: w1, w2, etc.
        $selectedIdx = @($response -split '[,\s]+' | ForEach-Object {
            $num = 0
            $cleaned = $_ -replace '[wW]', ''
            if ([int]::TryParse($cleaned.Trim(), [ref]$num)) { $num - 1 }
        } | Where-Object { $_ -ge 0 -and $_ -lt $groups.Count } | Select-Object -Unique)
        $windowGroups = @($selectedIdx | ForEach-Object { $groups[$_] })
    } else {
        # Individual tab selection: 1, 3, 5, etc. -- regroup picks by their original window
        $selectedTabs = @($response -split '[,\s]+' | ForEach-Object {
            $num = 0
            if ([int]::TryParse($_.Trim(), [ref]$num)) { $num }
        } | Where-Object { $sessionMap.ContainsKey($_) } | Select-Object -Unique)

        $tabGroups = [ordered]@{}
        foreach ($tabNum in $selectedTabs) {
            $gi, $si = $sessionMap[$tabNum]
            $g = $groups[$gi]
            if (-not $tabGroups.Contains($g.name)) {
                $tabGroups[$g.name] = [PSCustomObject]@{
                    name     = $g.name
                    tabColor = $g.tabColor
                    sessions = [System.Collections.ArrayList]::new()
                }
            }
            [void]$tabGroups[$g.name].sessions.Add($g.sessions[$si])
        }
        $windowGroups = @($tabGroups.Values)
    }
}

if ($windowGroups.Count -eq 0) {
    Write-Host "  No valid selection." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

Open-WorkspaceWindows -WindowGroups $windowGroups

if ($DryRun) {
    Write-Host "  Dry run: $totalTabs tab(s) across $totalWindows window(s) would open." -ForegroundColor Green
} else {
    Write-Host "  Done! Opened $totalTabs tab(s) across $totalWindows window(s)." -ForegroundColor Green
}
Write-Host ""
