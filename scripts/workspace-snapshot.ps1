# workspace-snapshot.ps1
# Captures LIVE Claude Code sessions, tiered by certainty:
#   [OPEN]  session confirmed by a running tab process (uuid in claude.exe cmdline,
#           happy-coder logs, or process-cwd matched to its project's newest .jsonl)
#   [OPEN?] an open tab exists but its session is inferred by recency (bare claude.exe
#           whose cwd could not be read or matched)
#   [F]     recent file activity only -- may already be closed
#   [BG]    running but not a terminal tab (happy remote sessions, daemon forks)
# Real Windows Terminal tab titles are shown as ground truth via UIAutomation.
#
# Usage: workspace-snapshot.bat                      (default: 30min file window, interactive)
#        workspace-snapshot.bat 60                   (custom file activity window in minutes)
#        workspace-snapshot.bat --auto               (non-interactive: save everything detected)
#        workspace-snapshot.bat --auto --open-only   (non-interactive: save only open/likely-open tabs)
#        workspace-snapshot.bat --out <file>         (write snapshot somewhere other than workspace.json)
#        workspace-snapshot.bat --agent codex        (claude | codex | all -- which agent's sessions to capture)
#
# The previous workspace.json is backed up to workspace-backups\ (newest 5 kept)
# before every save, and the new file is written atomically (temp + rename).

param(
    [int]$Minutes = 30,
    [switch]$Auto,
    [switch]$OpenOnly,
    [string]$OutFile,
    [string]$Agent = 'all'
)

function Show-SnapshotUsage {
    Write-Host ""
    Write-Host "  Usage: workspace-snapshot.bat [minutes] [--auto] [--open-only] [--out <file>] [--agent claude|codex|all]" -ForegroundColor Yellow
    Write-Host ""
}

# GNU-style flags that don't prefix-match a param name land in $args -- parse them here.
$badArgs = @()
for ($ai = 0; $ai -lt $args.Count; $ai++) {
    $a = "$($args[$ai])"
    $n = 0
    if ([int]::TryParse($a, [ref]$n)) { $Minutes = $n }
    elseif ($a -match '^--?auto$') { $Auto = $true }
    elseif ($a -match '^--?open-?only$') { $OpenOnly = $true }
    elseif ($a -match '^--?out(-?file)?$' -and $ai + 1 -lt $args.Count) { $OutFile = "$($args[$ai + 1])"; $ai++ }
    elseif ($a -match '^--?agent$' -and $ai + 1 -lt $args.Count) { $Agent = "$($args[$ai + 1])"; $ai++ }
    else { $badArgs += $a }
}
if ($badArgs.Count -gt 0) {
    Write-Host ""
    Write-Host "  Unknown argument(s): $($badArgs -join ', ')" -ForegroundColor Red
    Show-SnapshotUsage
    exit 1
}
if ($Minutes -lt 1) { $Minutes = 30 }

# Allowlisted -- $Agent selects code paths only, and is never interpolated into a
# command line or a path.
$Agent = "$Agent".ToLower()
if ($Agent -notin @('claude', 'codex', 'all')) {
    Write-Host ""
    Write-Host "  --agent must be claude, codex or all (got '$Agent')" -ForegroundColor Red
    Show-SnapshotUsage
    exit 1
}

$claudeDir = Join-Path $env:USERPROFILE '.claude'
$projectsDir = Join-Path $claudeDir 'projects'
$workspaceFile = Join-Path $claudeDir 'workspace.json'
if ($OutFile) {
    $workspaceFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
}

# Tab titles end up inside a cmd /c + wt.exe command line on restore -- keep them inert.
function Get-SafeTabName {
    param([string]$Name)
    if (-not $Name) { return '' }
    $n = $Name -replace '[\x00-\x1F"<>|&^%]', '' -replace ';', ','
    return ($n -replace '\s+', ' ').Trim()
}

$uuidRe = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

function Get-ProjectColor {
    param([string]$Name)
    [int]$hash = 5381
    foreach ($c in $Name.ToCharArray()) {
        $hash = (($hash * 33) + [int]$c) -band 0x7FFFFFFF
    }
    $idx = $hash % $colorPalette.Count
    return $colorPalette[$idx]
}

# Snapshot the full process table once -- initialised empty here so the function
# below is safe to define before STEP 1 actually builds the live table.
$allProcs = @{}

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

# Damerau-Levenshtein (optimal string alignment) so typo'd renames still find
# their project: "defromer" -> "deformers" is one transposition + one insert.
# Rolling 1-D rows: Windows PowerShell 5.1 cannot parse 2-D array indexing here.
function Get-EditDistance {
    param([string]$A, [string]$B)
    $la = $A.Length; $lb = $B.Length
    if ($la -eq 0) { return $lb }
    if ($lb -eq 0) { return $la }
    $prev2 = New-Object 'int[]' ($lb + 1)   # row x-2 (for transpositions)
    $prev  = New-Object 'int[]' ($lb + 1)   # row x-1
    $curr  = New-Object 'int[]' ($lb + 1)   # row x
    for ($y = 0; $y -le $lb; $y++) { $prev[$y] = $y }
    for ($x = 1; $x -le $la; $x++) {
        $curr[0] = $x
        for ($y = 1; $y -le $lb; $y++) {
            $cost = if ($A[$x - 1] -eq $B[$y - 1]) { 0 } else { 1 }
            $best = $prev[$y] + 1
            $t = $curr[$y - 1] + 1
            if ($t -lt $best) { $best = $t }
            $t = $prev[$y - 1] + $cost
            if ($t -lt $best) { $best = $t }
            if ($x -gt 1 -and $y -gt 1 -and $A[$x - 1] -eq $B[$y - 2] -and $A[$x - 2] -eq $B[$y - 1]) {
                $t = $prev2[$y - 2] + 1
                if ($t -lt $best) { $best = $t }
            }
            $curr[$y] = $best
        }
        $tmp = $prev2; $prev2 = $prev; $prev = $curr; $curr = $tmp
    }
    return $prev[$lb]
}

# SYSTEMTIME: wYear, wMonth, wDayOfWeek, wDay, wHour, wMinute, wSecond, wMilliseconds
# (16 bytes, little-endian UInt16 each). Event 6008 packs two: offset 0 is local
# time -- what the event message reports -- and offset 16 is UTC.
function ConvertFrom-SystemTimeBytes {
    param([byte[]]$Bytes, [int]$Offset = 0)
    if (-not $Bytes -or $Offset -lt 0 -or $Bytes.Length -lt ($Offset + 16)) { return $null }
    $y  = [BitConverter]::ToUInt16($Bytes, $Offset)
    $mo = [BitConverter]::ToUInt16($Bytes, $Offset + 2)
    $d  = [BitConverter]::ToUInt16($Bytes, $Offset + 6)
    $h  = [BitConverter]::ToUInt16($Bytes, $Offset + 8)
    $mi = [BitConverter]::ToUInt16($Bytes, $Offset + 10)
    $s  = [BitConverter]::ToUInt16($Bytes, $Offset + 12)
    $ms = [BitConverter]::ToUInt16($Bytes, $Offset + 14)
    if ($y -lt 1980 -or $y -gt 2200) { return $null }
    try { return New-Object DateTime $y, $mo, $d, $h, $mi, $s, $ms } catch { return $null }
}

# Locale fallback: Properties[0]/[1] are display strings peppered with RTL marks.
function ConvertFrom-ShutdownStrings {
    param($Event)
    if ($Event.Properties.Count -lt 2) { return $null }
    $t = "$($Event.Properties[0].Value)" -replace '[\u200e\u200f]', ''
    $d = "$($Event.Properties[1].Value)" -replace '[\u200e\u200f]', ''
    if (-not $t -or -not $d) { return $null }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse("$d $t", [ref]$parsed)) { return $parsed }
    return $null
}

# Latest shutdown marker strictly before $LastBoot.
#   6008      -> unexpected; time comes from the SYSTEMTIME blob, NOT TimeCreated
#                (6008 is written after the next boot).
#   1074/6006 -> clean; written before shutdown, so TimeCreated IS the time.
#   41        -> corroborates "unexpected" only. Its Properties are scalar zeros
#                on this platform, so it carries no usable timestamp.
function Resolve-LastShutdown {
    param([datetime]$LastBoot, $Events)
    $best = $null
    foreach ($e in @($Events)) {
        $t = $null
        $kind = $null
        if ([int]$e.Id -eq 6008) {
            $kind = 'unexpected'
            $blob = $null
            if ($e.Properties.Count -gt 7) { $blob = $e.Properties[7].Value }
            if ($blob -is [byte[]]) { $t = ConvertFrom-SystemTimeBytes -Bytes $blob -Offset 0 }
            if (-not $t) { $t = ConvertFrom-ShutdownStrings -Event $e }
        } elseif ([int]$e.Id -eq 1074 -or [int]$e.Id -eq 6006) {
            $kind = 'clean'
            $t = $e.TimeCreated
        }
        if ($t -and $t -lt $LastBoot) {
            if (-not $best -or $t -gt $best.time) {
                $best = [pscustomobject]@{ time = $t; kind = $kind }
            }
        }
    }
    if (-not $best) { $best = [pscustomobject]@{ time = $LastBoot; kind = 'assumed' } }
    return $best
}

# Live wrapper -- kept separate so Resolve-LastShutdown stays pure and testable.
function Get-LastShutdownInfo {
    param([datetime]$LastBoot)
    $events = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'System'; Id = 6008, 6006, 1074, 41
            StartTime = $LastBoot.AddDays(-30)
        } -ErrorAction Stop)
    } catch {}
    return Resolve-LastShutdown -LastBoot $LastBoot -Events $events
}

# Codex writes AGENTS.md and environment context as the first role:user items --
# the same class of synthetic prompt the Claude path already skips.
# Generalised on purpose: every synthetic shape Codex emits as a first role:user
# item is either the "# AGENTS.md instructions" heading or an XML-ish tag opening
# at position 0 (<environment_context, <user_instructions, <INSTRUCTIONS,
# <codex_internal_context, <recommended_plugins, <image, ...). New Codex versions
# keep adding new tag names -- matching "<" + a tag-name character generically
# means we don't need a code change every time one shows up. The explicit named
# tags are kept below only as documentation of shapes seen in the wild; the
# leading "<[A-Za-z]" branch is what actually does the work.
$script:codexSyntheticRe = '^\s*(#\s*AGENTS\.md instructions|</?[A-Za-z]|<environment_context|<user_instructions|<INSTRUCTIONS)'

# A running codex.exe holds its rollout file open for writing. [System.IO.File]::ReadLines
# and Get-Content open with the CLR default (FileShare.Read, and codex's own handle wants
# ReadWrite), so reading a LIVE rollout throws a sharing-violation IOException -- exactly
# the sessions this feature exists to capture. Open explicitly with FileShare.ReadWrite so
# our read is compatible with codex's own handle, and never throw out of this helper: a
# locked-harder-than-that or vanished file degrades to "no lines", not an aborted caller.
function Get-SharedFileLines {
    param([string]$Path, [int]$MaxLines = 0)
    # NOTE: every return below uses the unary comma (,$result) on purpose. Without it,
    # PowerShell enumerates the returned List[string] onto the output pipeline and the
    # caller's assignment collapses a 1-line result to a bare scalar string -- which then
    # silently mis-indexes as a single character ($lines[0] -> "{") instead of a full line.
    $result = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path)) { return ,$result }
    $fs = $null
    $sr = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        $sr = New-Object System.IO.StreamReader($fs)
        $n = 0
        while ($true) {
            $line = $sr.ReadLine()
            if ($null -eq $line) { break }
            $n++
            $result.Add($line)
            if ($MaxLines -gt 0 -and $n -ge $MaxLines) { break }
        }
    } catch {
        return ,$result
    } finally {
        if ($sr) { $sr.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
    return ,$result
}

function Get-CodexSessionMeta {
    param([string]$Path)
    $lines = Get-SharedFileLines -Path $Path -MaxLines 1
    if ($lines.Count -lt 1) { return $null }
    $line = $lines[0]
    if (-not $line) { return $null }
    try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ($obj.type -ne 'session_meta') { return $null }
    $p = $obj.payload
    # subagent threads are Codex's isSidechain -- never restorable as a tab
    if ("$($p.thread_source)" -ne 'user') { return $null }
    if (-not $p.session_id -or -not $p.cwd) { return $null }
    return [pscustomobject]@{
        sessionId = "$($p.session_id)"
        cwd       = "$($p.cwd)"
        started   = $p.timestamp
    }
}

function Get-CodexTitleMap {
    param([string]$IndexPath)
    $map = @{}
    foreach ($line in (Get-SharedFileLines -Path $IndexPath)) {
        if (-not $line) { continue }
        try { $o = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if (-not $o.id -or -not $o.thread_name) { continue }
        $u = [datetime]::MinValue
        try { $u = [datetime]::Parse($o.updated_at) } catch {}
        if (-not $map.ContainsKey($o.id) -or $u -ge $map[$o.id].updated) {
            $map[$o.id] = [pscustomobject]@{ name = "$($o.thread_name)"; updated = $u }
        }
    }
    return $map
}

function Get-CodexFirstPrompt {
    param([string]$Path, [int]$MaxLines = 400)
    foreach ($line in (Get-SharedFileLines -Path $Path -MaxLines $MaxLines)) {
        if ($line -notmatch '"role":"user"') { continue }
        try { $o = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($o.payload.role -ne 'user') { continue }
        foreach ($c in @($o.payload.content)) {
            if ($c.type -ne 'input_text' -or -not $c.text) { continue }
            if ($c.text -match $script:codexSyntheticRe) { continue }
            return $c.text
        }
    }
    return $null
}

# A Codex session holds an exclusive handle on its lock file for as long as it
# lives. Two races require handling: (1) a missing file between Test-Path and
# Open is checked upfront; (2) a file deleted between Test-Path and File.Open
# throws FileNotFoundException (IS-A IOException) -- catch it before IOException
# to return $false rather than incorrectly reporting a just-exited session as live.
# DirectoryNotFoundException is similarly preempted.
function Test-LockHeld {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $fs.Close()
        $fs.Dispose()
        return $false
    } catch [System.IO.FileNotFoundException] {
        return $false
    } catch [System.IO.DirectoryNotFoundException] {
        return $false
    } catch [System.IO.IOException] {
        return $true
    } catch {
        return $false
    }
}

function Get-CodexHeldLockIds {
    param([string]$LockDir)
    # Use List[string] to preserve array-ness on all return paths, including zero-length
    $ids = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $LockDir)) { return ,$ids }
    foreach ($f in @(Get-ChildItem -LiteralPath $LockDir -Filter '*.lock' -ErrorAction SilentlyContinue)) {
        if ($f.Name -eq '.coordination.lock') { continue }
        if ($f.BaseName -notmatch "^$uuidRe$") { continue }
        if (Test-LockHeld -Path $f.FullName) { $ids.Add($f.BaseName) }
    }
    return ,$ids
}

# Reads another process's current working directory out of its PEB (read-only, same
# user). Both the Claude bare-tab matcher (Method C) and the Codex pass need it, so it
# lives here as a helper instead of inside either one -- compiled at most once per run,
# and only on x64 where the PEB offsets below are correct. Callers keep using the
# ('WsSnapProcCwd' -as [type]) guard, which stays $null when compilation is impossible.
function Initialize-ProcCwdReader {
    if ('WsSnapProcCwd' -as [type]) { return }
    if (-not [Environment]::Is64BitProcess) { return }
    try {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class WsSnapProcCwd {
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int infoClass, ref PBI info, int len, out int retLen);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr read);
    [StructLayout(LayoutKind.Sequential)] struct PBI { public IntPtr ExitStatus; public IntPtr PebBaseAddress; public IntPtr AffinityMask; public IntPtr BasePriority; public IntPtr UniqueProcessId; public IntPtr InheritedFromUniqueProcessId; }
    public static string Get(uint pid) {
        IntPtr h = OpenProcess(0x0410, false, pid); // PROCESS_QUERY_INFORMATION | PROCESS_VM_READ
        if (h == IntPtr.Zero) return null;
        try {
            PBI pbi = new PBI(); int rl;
            if (NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(typeof(PBI)), out rl) != 0) return null;
            byte[] ptrBuf = new byte[8]; IntPtr rd;
            if (!ReadProcessMemory(h, pbi.PebBaseAddress + 0x20, ptrBuf, 8, out rd)) return null;   // PEB+0x20 = ProcessParameters (x64)
            IntPtr pp = (IntPtr)BitConverter.ToInt64(ptrBuf, 0);
            byte[] us = new byte[16];
            if (!ReadProcessMemory(h, pp + 0x38, us, 16, out rd)) return null;                      // +0x38 = CurrentDirectory.DosPath (UNICODE_STRING)
            ushort len = BitConverter.ToUInt16(us, 0);
            IntPtr strPtr = (IntPtr)BitConverter.ToInt64(us, 8);
            if (len == 0 || strPtr == IntPtr.Zero) return null;
            byte[] str = new byte[len];
            if (!ReadProcessMemory(h, strPtr, str, len, out rd)) return null;
            return Encoding.Unicode.GetString(str);
        } finally { CloseHandle(h); }
    }
}
'@
    } catch {}
}

# Test seam: dot-source with WSS_LOAD_ONLY=1 to get the functions without running the tool.
if ($env:WSS_LOAD_ONLY -eq '1') { return }

# --- STEP 1: Detect live session IDs (tiered by certainty) ---

# One recursive scan of ~/.claude/projects feeds every later step (Methods B/C,
# history mode, and per-session metadata) instead of rescanning per session.
$allJsonl = @()
if (Test-Path $projectsDir) {
    $allJsonl = @(Get-ChildItem -Path $projectsDir -Filter '*.jsonl' -Recurse -ErrorAction SilentlyContinue)
}
$jsonlById = @{}    # sessionId -> FileInfo (first match wins, like the old per-id search)
$jsonlByDir = @{}   # lowercased project dir -> [FileInfo]
foreach ($f in $allJsonl) {
    if ($f.BaseName -match "^$uuidRe$" -and -not $jsonlById.ContainsKey($f.BaseName)) {
        $jsonlById[$f.BaseName] = $f
    }
    $dirKey = $f.DirectoryName.ToLower()
    if (-not $jsonlByDir.ContainsKey($dirKey)) { $jsonlByDir[$dirKey] = [System.Collections.ArrayList]::new() }
    [void]$jsonlByDir[$dirKey].Add($f)
}

# Snapshot the full process table once
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
    $allProcs[[uint32]$_.ProcessId] = $_
}

$confirmedOpen = @{}   # sessionId -> $true : uuid confirmed by a process inside a terminal tab
$confirmedBg   = @{}   # sessionId -> $true : uuid confirmed by a process NOT in a tab (remote/daemon)
$bareOpenCount = 0     # interactive claude.exe tabs whose session id is unknowable
$bareTabProcs  = [System.Collections.ArrayList]::new()   # the bare-tab processes themselves (for Method C)

# Methods A/H/C are Claude-specific: they read claude.exe command lines, happy-coder
# logs and ~/.claude/projects. --agent codex skips them wholesale.
if ($Agent -in @('claude', 'all')) {
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
            [void]$bareTabProcs.Add($p)
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

    # Method C: bare-tab cwd matching — a bare claude.exe (no uuid in its cmdline) still
    # betrays its session: read the process's working directory out of its PEB (read-only,
    # same-user), map it to the matching ~/.claude/projects dir, and take the newest .jsonl
    # CREATED since that process launched (a bare claude.exe creates its session file within
    # seconds of starting; /clear successors are created later in its lifetime). Newest tabs
    # claim files first so two tabs in the same project don't grab each other's session.
    # Unmatched tabs stay in $bareOpenCount and fall back to the recency promotion below.
    if ($bareTabProcs.Count -gt 0) {
        Initialize-ProcCwdReader
        if ('WsSnapProcCwd' -as [type]) {
            $claimedIds = @{}
            foreach ($k in $confirmedOpen.Keys) { $claimedIds[$k] = $true }
            foreach ($k in $confirmedBg.Keys)   { $claimedIds[$k] = $true }
            foreach ($p in @($bareTabProcs | Sort-Object CreationDate -Descending)) {
                $procCwd = $null
                try { $procCwd = [WsSnapProcCwd]::Get([uint32]$p.ProcessId) } catch {}
                if (-not $procCwd) { continue }
                # Claude Code encodes a project dir by replacing every non-alphanumeric char with '-'
                $projDirName = $procCwd.TrimEnd('\') -replace '[^A-Za-z0-9]', '-'
                $projDirKey = (Join-Path $projectsDir $projDirName).ToLower()
                if (-not $jsonlByDir.ContainsKey($projDirKey)) { continue }
                $startSlack = $p.CreationDate.AddSeconds(-60)
                $candidates = @($jsonlByDir[$projDirKey] |
                    Where-Object {
                        $_.BaseName -match "^$uuidRe$" -and
                        -not $claimedIds.ContainsKey($_.BaseName) -and
                        $_.LastWriteTime -ge $startSlack
                    })
                # Files created before the process belong to OTHER sessions, however fresh
                # their mtime looks (a tab closed minutes ago, a remote resume of an old
                # session). Claiming by mtime alone let such a file steal the tab's identity
                # and pushed the tab's real session out of the list entirely. Fall back to
                # pure recency only when no created-after file exists (in-app /resume).
                $ownCreated = @($candidates | Where-Object { $_.CreationTime -ge $startSlack })
                if ($ownCreated.Count -gt 0) { $candidates = $ownCreated }
                $match = $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($match) {
                    $confirmedOpen[$match.BaseName] = $true
                    $claimedIds[$match.BaseName] = $true
                    $bareOpenCount--
                }
            }
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

# $recentCutoff is shared by Method B and the Codex pass -- compute it unconditionally.
$recentCutoff = (Get-Date).AddMinutes(-$Minutes)

# Method B: .jsonl files modified recently (catches sessions invisible to A/H)
$recentIds = @()
if ($Agent -in @('claude', 'all')) {
    $recentIds = @($allJsonl |
        Where-Object { $_.LastWriteTime -gt $recentCutoff -and $_.BaseName -match '^[0-9a-f]{8}-' } |
        ForEach-Object { $_.BaseName })
}

# Combine and deduplicate
$processIds = @($confirmedOpen.Keys) + @($confirmedBg.Keys)
$liveIds = @($processIds + $recentIds | Select-Object -Unique)

# --- Codex discovery -------------------------------------------------------
# Codex keeps one rollout-<ts>-<uuid>.jsonl per thread under ~/.codex/sessions and
# holds an exclusive lock file per LIVE thread under ~/.codex/thread-writer-locks.
# codex.exe carries no session id on its command line, so a held lock only proves
# the session is alive -- to tell an on-screen tab from a background/remote codex we
# match the session's own cwd against the cwds of the codex.exe processes that sit
# under a WindowsTerminal.exe.
$codexRecords = [System.Collections.ArrayList]::new()
$codexRolloutById = @{}    # sessionId -> rollout FileInfo (every rollout examined, kept or not)
$codexDir = Join-Path $env:USERPROFILE '.codex'
if ($Agent -in @('codex', 'all') -and (Test-Path $codexDir)) {
    $codexSessionsDir = Join-Path $codexDir 'sessions'
    $heldIds = @{}
    foreach ($id in (Get-CodexHeldLockIds -LockDir (Join-Path $codexDir 'thread-writer-locks'))) {
        $heldIds[$id] = $true
    }
    $titleMap = Get-CodexTitleMap -IndexPath (Join-Path $codexDir 'session_index.jsonl')

    # cwd -> is that cwd backed by a codex.exe inside a Windows Terminal tab?
    $codexTabCwds = @{}
    Initialize-ProcCwdReader
    foreach ($p in $allProcs.Values) {
        if ($p.Name -ne 'codex.exe') { continue }
        if (-not (Test-UnderWindowsTerminal ([uint32]$p.ProcessId))) { continue }
        $c = $null
        if ('WsSnapProcCwd' -as [type]) {
            try { $c = [WsSnapProcCwd]::Get([uint32]$p.ProcessId) } catch {}
        }
        if ($c) { $codexTabCwds[$c.TrimEnd('\').ToLower()] = $true }
    }

    $rollouts = @()
    if (Test-Path $codexSessionsDir) {
        $rollouts = @(Get-ChildItem -Path $codexSessionsDir -Filter 'rollout-*.jsonl' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt $recentCutoff -or $heldIds.ContainsKey(($_.BaseName -replace "^.*?($uuidRe)$", '$1')) })
    }

    foreach ($f in $rollouts) {
        if ($f.BaseName -notmatch "($uuidRe)$") { continue }
        $sid = $Matches[1]
        # Indexed for every rollout we look at, kept or dropped -- history recovery
        # (Task 7) hydrates its rows from this map and cannot rebuild it.
        if (-not $codexRolloutById.ContainsKey($sid)) { $codexRolloutById[$sid] = $f }
        $meta = Get-CodexSessionMeta -Path $f.FullName
        if (-not $meta) { continue }          # subagent thread or unparsable
        $tier = 'recent'
        if ($heldIds.ContainsKey($sid)) {
            $tier = if ($codexTabCwds.ContainsKey($meta.cwd.TrimEnd('\').ToLower())) { 'open' } else { 'background' }
        }
        $title = $null
        if ($titleMap.ContainsKey($sid)) { $title = $titleMap[$sid].name }
        $prompt = Get-CodexFirstPrompt -Path $f.FullName
        if (-not $title) { $title = $prompt }
        # Never drop a real session for lack of a title: a brand-new thread has no
        # session_index entry yet and may have nothing but synthetic preamble so far.
        # A weak row (the project name) beats a missing one.
        if (-not $title) { $title = Split-Path $meta.cwd -Leaf }
        if (-not $title) { continue }
        [void]$codexRecords.Add([pscustomobject]@{
            sessionId = $sid; agent = 'codex'; cwd = $meta.cwd
            title = $title; firstPrompt = $prompt
            modified = $f.LastWriteTime; tier = $tier
        })
    }
}

# --- STEP 1b: History recovery fallback (only when no live sessions) ---
# Triggered after a reboot/blackout where every Claude session was closed.
# Live sessions always win — this branch is only reachable when $liveIds is empty.

$historyMode = $false
$historySubtitle = ''

if ($liveIds.Count -eq 0 -and $codexRecords.Count -eq 0) {
    $agentLabel = switch ($Agent) { 'claude' { 'Claude' } 'codex' { 'Codex' } default { 'Claude or Codex' } }
    Write-Host ""
    Write-Host "  No live $agentLabel sessions detected." -ForegroundColor Yellow
    Write-Host "  (checked running processes + files modified in last $Minutes min)" -ForegroundColor DarkGray
    Write-Host ""

    # History recovery still only knows how to read ~/.claude/projects, so it has
    # nothing to offer a Codex-only run. Bail out rather than prompt for a search
    # that could only ever return Claude sessions.
    if ($Agent -eq 'codex') { exit 0 }

    if ($Auto) {
        # A scheduled/non-interactive run must never overwrite a good pre-reboot
        # snapshot with history guesses. Leave workspace.json alone and bail out.
        Write-Host "  Auto mode: nothing saved (workspace.json left untouched)." -ForegroundColor DarkGray
        Write-Host ""
        exit 0
    }

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
        $historyIds = @($allJsonl |
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
        $historyIds = @($allJsonl |
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

$sessions = [System.Collections.ArrayList]::new()
$haystacks = @{}         # sessionId -> normalized metadata text, used for tab-title matching
$strongHaystacks = @{}   # sessionId -> same minus firstPrompt (title/summary/project/slug only)

# Read each live session's .jsonl file (located via the index built in STEP 1)
foreach ($sid in $liveIds) {
    if (-not $jsonlById.ContainsKey($sid)) { continue }
    $jsonlFile = $jsonlById[$sid]

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
    $tabName = Get-SafeTabName ($summary -replace '<[^>]+>', '')
    if ($tabName.Length -gt 40) { $tabName = $tabName.Substring(0, 37) + '...' }

    $project = Split-Path $cwd -Leaf

    $tabColor = Get-ProjectColor $project

    $haystacks[$sid] = ("$aiTitle $summary $firstPrompt $project $slug").ToLower() -replace '[^a-z0-9]', ''
    $strongHaystacks[$sid] = ("$aiTitle $summary $project $slug").ToLower() -replace '[^a-z0-9]', ''

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
        agent       = 'claude'
        projectPath = $cwd
        project     = $project
        summary     = $summary
        tabName     = Get-SafeTabName "$project`: $tabName"
        tabColor    = $tabColor
        firstPrompt = if ($firstPrompt.Length -gt 80) { $firstPrompt.Substring(0, 77) + '...' } else { $firstPrompt }
        modified    = $jsonlFile.LastWriteTime.ToString('o')
        gitBranch   = $gitBranch
        slug        = $slug
        group       = $project
        source      = $source
        tier        = $tier
        tabLabel    = ''
    })
}

# Fold the Codex pass into the same record shape, so tab-title matching, grouping,
# display and save all stay agent-agnostic from here down. Codex has no equivalent of
# ai-title/summary/slug/gitBranch, so those stay empty and the thread name (or first
# real prompt) carries the display.
foreach ($c in $codexRecords) {
    $cProject = Split-Path $c.cwd -Leaf
    $cTabName = Get-SafeTabName ($c.title -replace '<[^>]+>', '')
    if ($cTabName.Length -gt 40) { $cTabName = $cTabName.Substring(0, 37) + '...' }

    $codexPrompt = ''
    if ($c.firstPrompt) {
        $codexPrompt = if ($c.firstPrompt.Length -gt 80) { $c.firstPrompt.Substring(0, 77) + '...' } else { $c.firstPrompt }
    }

    $haystacks[$c.sessionId] = ("$($c.title) $($c.firstPrompt) $cProject").ToLower() -replace '[^a-z0-9]', ''
    $strongHaystacks[$c.sessionId] = ("$($c.title) $cProject").ToLower() -replace '[^a-z0-9]', ''

    $cSource = if ($c.tier -eq 'open' -or $c.tier -eq 'background') { 'process' } else { 'file' }

    [void]$sessions.Add([PSCustomObject]@{
        sessionId   = $c.sessionId
        agent       = 'codex'
        projectPath = $c.cwd
        project     = $cProject
        summary     = $c.title
        tabName     = Get-SafeTabName "$cProject`: $cTabName"
        tabColor    = Get-ProjectColor $cProject
        firstPrompt = $codexPrompt
        modified    = $c.modified.ToString('o')
        gitBranch   = ''
        slug        = ''
        group       = $cProject
        source      = $cSource
        tier        = $c.tier
        tabLabel    = ''
    })
}

# Promote: we counted bare interactive claude.exe tabs (no uuid in cmdline) — the
# N most recently active unconfirmed sessions are most likely those open tabs
if (-not $historyMode -and $bareOpenCount -gt 0) {
    @($sessions | Where-Object { $_.tier -eq 'recent' -and $_.agent -eq 'claude' } |
        Sort-Object @{Expression={[DateTime]::Parse($_.modified)}; Descending=$true} |
        Select-Object -First $bareOpenCount) |
        ForEach-Object { $_.tier = 'maybe' }
}

# --open-only: keep just the tabs that are (probably) on screen right now
if ($OpenOnly -and -not $historyMode) {
    $sessions = @($sessions | Where-Object { $_.tier -in @('open', 'maybe') })
}

# Sort by tier (open > maybe > recent > background), then project group, then newest first
$tierOrder = @{ open = 0; maybe = 1; recent = 2; background = 3; history = 4 }
$sessions = @($sessions | Sort-Object @{Expression={$tierOrder[$_.tier]}}, @{Expression={$_.group}}, @{Expression={[DateTime]::Parse($_.modified)}; Descending=$true})

# --- Best-effort: label sessions with the real terminal tab names ---
# Tab titles (often manual renames) live only in the terminal -- match their words
# against session metadata. Conservative: EVERY word of the tab name must appear,
# one tab per session, so labels are never wild guesses (unmatched tabs stay unlabeled).

# Clean the tab list: strip spinner glyphs, drop plain-shell tabs (path-like titles)
$cleanTabs = @()
foreach ($t in $openTabTitles) {
    $tt = ($t -replace '[^\x20-\x7E]', '').Trim()
    if (-not $tt -or $tt -match '[\\/]' -or $tt -match '^[A-Za-z]:') { continue }
    $cleanTabs += $tt
}

if (-not $historyMode -and $cleanTabs.Count -gt 0) {
    $openSessions = @($sessions | Where-Object { $_.tier -in @('open', 'maybe') })
    $byProject = @{}
    foreach ($s in $openSessions) {
        if (-not $byProject.ContainsKey($s.project)) { $byProject[$s.project] = [System.Collections.ArrayList]::new() }
        [void]$byProject[$s.project].Add($s)
    }

    $pairs = @()
    $projPairs = @()
    foreach ($tab in $cleanTabs) {
        $tokens = @([regex]::Matches($tab.ToLower(), '[a-z0-9]{4,}') | ForEach-Object { $_.Value })
        if ($tokens.Count -eq 0) { continue }
        foreach ($s in $openSessions) {
            # Single-word renames only match high-signal metadata (title/summary/project/
            # slug). First prompts are often shared boilerplate -- "matter" appears in
            # every handoff template -- and one generic word hitting boilerplate used to
            # pin the tab name on an unrelated session.
            $hay = if ($tokens.Count -ge 2) { $haystacks[$s.sessionId] } else { $strongHaystacks[$s.sessionId] }
            if (-not $hay) { continue }
            $hits = 0
            foreach ($tok in $tokens) {
                $found = $hay.Contains($tok)
                if (-not $found) {
                    # singular form ("trees" should match "SpeedTree")
                    $t2 = $tok.TrimEnd('s')
                    if ($t2.Length -ge 4 -and $hay.Contains($t2)) { $found = $true }
                }
                if (-not $found -and $tok.Length -ge 8) {
                    # concatenated rename ("charcterworkflow" = "charcter" + "workflow")
                    for ($cut = 4; $cut -le ($tok.Length - 4); $cut++) {
                        if ($hay.Contains($tok.Substring(0, $cut)) -and $hay.Contains($tok.Substring($cut))) { $found = $true; break }
                    }
                }
                if ($found) { $hits++ }
            }
            if ($hits -eq $tokens.Count) {
                $pairs += [PSCustomObject]@{ tab = $tab; s = $s; score = $tokens.Count }
            }
        }
        # Rescue pass: typo'd renames ("defromer_New_ones", "Raytracer_A_Vulkan") never
        # pass the all-words test. If exactly one word clearly names exactly one project
        # (substring either way, or edit distance <= 2) and that project has exactly one
        # open session, the pairing is unambiguous. Anything less stays unlabeled.
        $projHit = $null; $ambiguous = $false
        foreach ($proj in $byProject.Keys) {
            $pn = $proj.ToLower() -replace '[^a-z0-9]', ''
            if ($pn.Length -lt 4) { continue }
            foreach ($tok in $tokens) {
                $near = $pn.Contains($tok) -or $tok.Contains($pn)
                if (-not $near -and $tok.Length -ge 5 -and [Math]::Abs($tok.Length - $pn.Length) -le 3) {
                    $near = (Get-EditDistance $tok $pn) -le 2
                }
                if ($near) {
                    if ($projHit -and $projHit -ne $proj) { $ambiguous = $true }
                    $projHit = $proj
                    break
                }
            }
        }
        if ($projHit -and -not $ambiguous -and $byProject[$projHit].Count -eq 1) {
            $projPairs += [PSCustomObject]@{ tab = $tab; s = $byProject[$projHit][0]; score = 0 }
        }
    }
    # Greedy unique assignment: exact matches (most words first), then project rescues
    $usedTabs = @{}
    foreach ($pair in @(@($pairs | Sort-Object score -Descending) + $projPairs)) {
        if ($usedTabs.ContainsKey($pair.tab) -or $pair.s.tabLabel) { continue }
        $pair.s.tabLabel = $pair.tab
        $usedTabs[$pair.tab] = $true
        # Restored tabs should come back with the user's own name -- and without
        # stacking a second "project:" prefix when the tab already carries one
        # from a previous restore ("SIMANGO: SIMANGO: ...")
        if ($pair.tab.ToLower().StartsWith("$($pair.s.project.ToLower()):")) {
            $pair.s.tabName = Get-SafeTabName $pair.tab
        } else {
            $pair.s.tabName = Get-SafeTabName "$($pair.s.project)`: $($pair.tab)"
        }
    }
}

if ($sessions.Count -eq 0) {
    Write-Host ""
    if ($OpenOnly) {
        Write-Host "  No open sessions found (--open-only)." -ForegroundColor Yellow
    } else {
        Write-Host "  No valid live sessions found." -ForegroundColor Yellow
    }
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
    if ($cleanTabs.Count -gt 0) {
        $titleList = ($cleanTabs | ForEach-Object { if ($_.Length -gt 25) { $_.Substring(0, 22) + '...' } else { $_ } }) -join ', '
        Write-Host "  Open terminal tabs ($($cleanTabs.Count)): " -NoNewline -ForegroundColor DarkGray
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
    if ($s.tabLabel -and $s.tabLabel -ne $summary) {
        Write-Host "[$($s.tabLabel)] " -NoNewline -ForegroundColor Cyan
    }
    Write-Host "$summary" -NoNewline
    Write-Host "$branch" -NoNewline -ForegroundColor Yellow
    Write-Host "$tierTag" -NoNewline -ForegroundColor $tierColor
    Write-Host " $time" -ForegroundColor DarkGray
}

Write-Host ""

# Ask user which sessions to save (default: all; 'o' = open + likely-open tabs only).
# In --auto mode, save everything shown without prompting (scheduled-task friendly).
$selected = @()
if ($Auto) {
    Write-Host "  Auto mode: saving all $($sessions.Count) session(s)." -ForegroundColor DarkGray
    $selected = 0..($sessions.Count - 1)
} else {
    $response = Read-Host "  Save all? [Y/n/o=open only] or enter numbers (e.g. 1,3,5)"

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

try {
    # Keep the last few snapshots: a bad save must never destroy the one good
    # pre-reboot workspace.json. Newest 5 backups are kept next to the target.
    if (Test-Path $workspaceFile) {
        $backupDir = Join-Path (Split-Path -Parent $workspaceFile) 'workspace-backups'
        if (-not (Test-Path $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }
        $stamp = (Get-Item $workspaceFile).LastWriteTime.ToString('yyyyMMdd-HHmmss')
        Copy-Item $workspaceFile (Join-Path $backupDir "workspace-$stamp.json") -Force
        Get-ChildItem -Path $backupDir -Filter 'workspace-*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # Atomic write: temp file + rename, so a crash mid-write can't truncate the snapshot
    $tmpFile = "$workspaceFile.tmp"
    $workspace | ConvertTo-Json -Depth 6 | Set-Content $tmpFile -Encoding UTF8
    Move-Item -Path $tmpFile -Destination $workspaceFile -Force
} catch {
    Write-Host "  ERROR: could not write $workspaceFile -- $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    exit 1
}

$tabCount = ($groupList | ForEach-Object { $_.sessions.Count } | Measure-Object -Sum).Sum
Write-Host "  Saved $tabCount session(s) in $($groupList.Count) window group(s) to $workspaceFile" -ForegroundColor Green
Write-Host "  Run workspace-restore.bat to reopen after restart." -ForegroundColor DarkGray
Write-Host ""
