# tests/test-baretab.ps1
# Select-BareTabMatches decides which transcript a bare claude.exe tab OWNS. Get it
# wrong and a live tab either vanishes from the snapshot (demoted to a [F] "recent file
# activity" row) or is labelled with another tab's session, which restore then reopens
# as a duplicate. Fixtures are PSCustomObjects carrying only the three properties the
# matcher reads (BaseName / CreationTime / LastWriteTime) plus a fake cwd table, so the
# test never touches real processes or real transcripts.
$env:WSS_LOAD_ONLY = '1'
. (Join-Path $script:repoRoot 'scripts\workspace-snapshot.ps1')
Remove-Item Env:\WSS_LOAD_ONLY -ErrorAction SilentlyContinue

$script:projRoot = 'C:\fake\.claude\projects'
$script:now = Get-Date

function New-Jsonl {
    param([string]$Id, [datetime]$Created, [datetime]$Modified)
    [pscustomobject]@{ BaseName = $Id; CreationTime = $Created; LastWriteTime = $Modified }
}
function New-Proc {
    param([int]$ProcId, [datetime]$Started)
    [pscustomobject]@{ ProcessId = $ProcId; CreationDate = $Started }
}
# $jsonlByDir is keyed by the LOWERCASED project dir, exactly as STEP 1 builds it.
function New-DirIndex {
    param([string]$Cwd, $Files)
    $key = (Join-Path $script:projRoot ($Cwd.TrimEnd('\') -replace '[^A-Za-z0-9]', '-')).ToLower()
    $list = [System.Collections.ArrayList]::new()
    foreach ($f in $Files) { [void]$list.Add($f) }
    return @{ $key = $list }
}
function New-CwdResolver {
    param([hashtable]$Map)   # pid -> cwd
    return { param([uint32]$procId) $Map[[int]$procId] }.GetNewClosure()
}

$idA = 'aaaaaaaa-1111-2222-3333-444444444444'
$idB = 'bbbbbbbb-1111-2222-3333-444444444444'

It 'a transcript created after the process launched is claimed' {
    # The common case: `claude` with no args writes its session file seconds after start.
    $proc = New-Proc 100 $script:now.AddMinutes(-30)
    $idx  = New-DirIndex 'C:\work\VTWO' @(
        (New-Jsonl $idA $script:now.AddMinutes(-29) $script:now.AddMinutes(-2)))
    $got = @(Select-BareTabMatches -Procs @($proc) -JsonlByDir $idx -ClaimedIds @{} `
                -ProjectsDir $script:projRoot -CwdResolver (New-CwdResolver @{ 100 = 'C:\work\VTWO' }))
    Assert-Equal 1 $got.Count 'the created-since-launch transcript must be claimed'
    Assert-Equal $idA $got[0] 'and it must be the right one'
}

It 'a transcript that predates the process but was written since launch is claimed' {
    # "claude --resume <id>" reuses a transcript created days ago and carries no uuid in
    # its command line, so creation time can never identify it -- but the live tab keeps
    # appending to it. Without this fallback the tab is missing from the snapshot.
    $proc = New-Proc 101 $script:now.AddMinutes(-30)
    $idx  = New-DirIndex 'C:\work\VTWO' @(
        (New-Jsonl $idA $script:now.AddDays(-6) $script:now.AddMinutes(-3)))
    $got = @(Select-BareTabMatches -Procs @($proc) -JsonlByDir $idx -ClaimedIds @{} `
                -ProjectsDir $script:projRoot -CwdResolver (New-CwdResolver @{ 101 = 'C:\work\VTWO' }))
    Assert-Equal 1 $got.Count 'a resumed session must still be matched to its process'
    Assert-Equal $idA $got[0] 'and it must be that resumed transcript'
}

It 'a transcript untouched since the process launched is NOT claimed' {
    # An idle resumed tab is genuinely unidentifiable, and a transcript whose last write
    # predates the launch belongs to some other (closed or remote) session. Claiming it
    # would put the wrong session id on the tab.
    $proc = New-Proc 102 $script:now.AddMinutes(-30)
    $idx  = New-DirIndex 'C:\work\VTWO' @(
        (New-Jsonl $idA $script:now.AddDays(-6) $script:now.AddMinutes(-90)))
    $got = @(Select-BareTabMatches -Procs @($proc) -JsonlByDir $idx -ClaimedIds @{} `
                -ProjectsDir $script:projRoot -CwdResolver (New-CwdResolver @{ 102 = 'C:\work\VTWO' }))
    Assert-Equal 0 $got.Count 'a stale transcript must be left to the bare-tab count'
}

It 'two processes in one project cannot claim the same transcript' {
    # Only one transcript is claimable; the second tab must come away empty rather than
    # duplicating the first tab's session.
    $procs = @((New-Proc 103 $script:now.AddMinutes(-10)), (New-Proc 104 $script:now.AddMinutes(-40)))
    $idx   = New-DirIndex 'C:\work\VTWO' @(
        (New-Jsonl $idA $script:now.AddMinutes(-9) $script:now.AddMinutes(-1)))
    $got = @(Select-BareTabMatches -Procs $procs -JsonlByDir $idx -ClaimedIds @{} `
                -ProjectsDir $script:projRoot `
                -CwdResolver (New-CwdResolver @{ 103 = 'C:\work\VTWO'; 104 = 'C:\work\VTWO' }))
    Assert-Equal 1 $got.Count 'one transcript can only be claimed once'
    Assert-Equal $idA $got[0] 'and it goes to the only tab that can own it'
}

It 'a resumed tab and a fresh tab in one project are both identified' {
    # proc 105 (newest) is a resumed tab whose own transcript $idB predates it; proc 106
    # is a fresh tab whose transcript $idA was created at ITS launch. Neither may go
    # unidentified, and neither transcript may be handed out twice -- a project where
    # some tabs are resumed and some are not is the ordinary case, not an edge case.
    $procs = @((New-Proc 105 $script:now.AddMinutes(-10)), (New-Proc 106 $script:now.AddMinutes(-40)))
    $idx   = New-DirIndex 'C:\work\VTWO' @(
        (New-Jsonl $idA $script:now.AddMinutes(-39) $script:now.AddMinutes(-1)),
        (New-Jsonl $idB $script:now.AddDays(-6)     $script:now.AddMinutes(-2)))
    $got = @(Select-BareTabMatches -Procs $procs -JsonlByDir $idx -ClaimedIds @{} `
                -ProjectsDir $script:projRoot `
                -CwdResolver (New-CwdResolver @{ 105 = 'C:\work\VTWO'; 106 = 'C:\work\VTWO' }))
    Assert-Equal 2 $got.Count 'both tabs must be identified'
    Assert-True ($got -contains $idA) 'the fresh tab keeps the transcript created at its launch'
    Assert-True ($got -contains $idB) 'the resumed tab gets its own older transcript'
}

It 'a never-appended stub transcript is not claimable' {
    # Claude Code drops a one-line {"type":"bridge-session"} stub for sessions that never
    # took a prompt; it is written once at creation, so LastWriteTime == CreationTime to
    # the tick. Get-ClaudeSessionRecord discards it (no prompt, no cwd), so claiming one
    # spends the tab's only claim and yields no row -- the tab vanishes from the snapshot.
    $stamp = $script:now.AddMinutes(-20)
    $proc  = New-Proc 110 $script:now.AddMinutes(-30)
    $idx   = New-DirIndex 'C:\work\VTWO' @((New-Jsonl $idA $stamp $stamp))
    $got = @(Select-BareTabMatches -Procs @($proc) -JsonlByDir $idx -ClaimedIds @{} `
                -ProjectsDir $script:projRoot -CwdResolver (New-CwdResolver @{ 110 = 'C:\work\VTWO' }))
    Assert-Equal 0 $got.Count 'a stub that can never produce a row must not be claimed'
}

It 'a stub does not cost a resumed tab its real transcript' {
    # The measured failure: a long-lived resumed tab (its own transcript $idB predates it)
    # sharing a project with an abandoned stub $idA that WAS created during its lifetime.
    # If the stub is claimable, pass 1 takes it, the row is dropped as unrestorable, and
    # $idB is orphaned to the [F] tier even though its tab is plainly open.
    $stamp = $script:now.AddMinutes(-20)
    $proc  = New-Proc 111 $script:now.AddMinutes(-40)
    $idx   = New-DirIndex 'C:\work\VTWO' @(
        (New-Jsonl $idA $stamp                 $stamp),
        (New-Jsonl $idB $script:now.AddDays(-6) $script:now.AddMinutes(-2)))
    $got = @(Select-BareTabMatches -Procs @($proc) -JsonlByDir $idx -ClaimedIds @{} `
                -ProjectsDir $script:projRoot -CwdResolver (New-CwdResolver @{ 111 = 'C:\work\VTWO' }))
    Assert-Equal 1 $got.Count 'the tab must still be identified'
    Assert-Equal $idB $got[0] 'and by its real transcript, not the stub created during its lifetime'
}

It 'an already-claimed transcript is never handed out again' {
    # Methods A and H seed $claimedIds with uuids they confirmed from command lines and
    # happy-coder logs; Method C must not re-issue one of those to a different process.
    $proc = New-Proc 107 $script:now.AddMinutes(-30)
    $idx  = New-DirIndex 'C:\work\VTWO' @(
        (New-Jsonl $idA $script:now.AddMinutes(-29) $script:now.AddMinutes(-2)))
    $got = @(Select-BareTabMatches -Procs @($proc) -JsonlByDir $idx -ClaimedIds @{ $idA = $true } `
                -ProjectsDir $script:projRoot -CwdResolver (New-CwdResolver @{ 107 = 'C:\work\VTWO' }))
    Assert-Equal 0 $got.Count 'a uuid confirmed elsewhere must stay with its owner'
}

It 'a process whose cwd is unreadable or unknown is skipped' {
    # The PEB read fails for elevated / cross-session processes, and a cwd with no
    # matching project dir means the tab has no transcript to claim.
    $procs = @((New-Proc 108 $script:now.AddMinutes(-30)), (New-Proc 109 $script:now.AddMinutes(-30)))
    $idx   = New-DirIndex 'C:\work\VTWO' @(
        (New-Jsonl $idA $script:now.AddMinutes(-29) $script:now.AddMinutes(-2)))
    $got = @(Select-BareTabMatches -Procs $procs -JsonlByDir $idx -ClaimedIds @{} `
                -ProjectsDir $script:projRoot `
                -CwdResolver (New-CwdResolver @{ 108 = $null; 109 = 'C:\work\ELSEWHERE' }))
    Assert-Equal 0 $got.Count 'neither process can name a transcript'
}
