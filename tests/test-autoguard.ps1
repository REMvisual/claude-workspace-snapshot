# tests/test-autoguard.ps1
# The two --auto write refusals, exercised end to end against the real script under a
# fake USERPROFILE. Real claude.exe / codex.exe processes on the box are still detected,
# but their session ids do not exist under these fixture directories, so the only rows
# each run can build are the ones the fixture puts there.

function New-FakeHome {
    $fake = Join-Path $env:TEMP ("wss-guard-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $fake '.claude\projects\C--Fake-Guard') -Force | Out-Null
    return $fake
}

function New-FakeTranscript {
    param([string]$FakeHome, [string]$Uuid, [string]$Title, [datetime]$Modified)
    # ${Uuid} braces are load-bearing: "$Uuid.jsonl" parses as a PROPERTY access.
    $path = Join-Path $FakeHome ".claude\projects\C--Fake-Guard\${Uuid}.jsonl"
    # Both elements parenthesized: PowerShell binds ',' TIGHTER than '+', so an
    # unparenthesized concatenation swallows the next element and writes ONE line.
    [System.IO.File]::WriteAllLines($path, @(
        ('{"type":"user","cwd":"C:\\Fake\\Guard","gitBranch":"master","message":{"role":"user","content":"do the thing for ' + $Uuid + '"}}'),
        ('{"type":"ai-title","aiTitle":"' + $Title + '"}')
    ), (New-Object System.Text.UTF8Encoding($false)))
    (Get-Item -LiteralPath $path).LastWriteTime = $Modified
    return $path
}

function Write-FakeWorkspace {
    param([string]$FakeHome, [string[]]$Uuids, [datetime]$Modified, [string]$Tier = 'open')
    $rows = @($Uuids | ForEach-Object {
        '{ "sessionId": "' + $_ + '", "agent": "claude", "tabName": "Guard: ' + $_ + '", "tabColor": "#111111", "modified": "2026-01-01T00:00:00", "tier": "' + $Tier + '" }'
    }) -join ', '
    $ws = Join-Path $FakeHome '.claude\workspace.json'
    [System.IO.File]::WriteAllText($ws,
        ('{ "created": "2026-01-01T00:00:00", "groups": [ { "name": "Guard", "tabColor": "#111111", "sessions": [ ' + $rows + ' ] } ] }'),
        [System.Text.Encoding]::ASCII)
    (Get-Item -LiteralPath $ws).LastWriteTime = $Modified
    return $ws
}

function Get-LastBootOrFallback {
    $b = $null
    try { $b = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch {}
    if (-not $b) { $b = (Get-Date).AddHours(-3) }
    return $b
}

function Invoke-Snapshot {
    param([string]$FakeHome, [string[]]$SnapArgs)
    $saved = $env:USERPROFILE
    try {
        $env:USERPROFILE = $FakeHome
        # Feed the child a decline on stdin, on EVERY launch and not just the calls that
        # currently reach a prompt. `2>&1` redirects the child's STDOUT only, so without
        # this its stdin is inherited from whatever the harness happened to have: at EOF
        # under CI (Read-Host returns instantly, which is why this looked fine) but a live
        # console for a developer running run-tests.ps1 by hand, where an interactive run
        # would block on a keypress whose prompt is swallowed by the output capture -- and
        # run-tests.ps1 has no timeout, so the suite would simply appear to hang.
        #
        # `n` and NOT -NonInteractive: measured, -NonInteractive does not stop Read-Host,
        # it makes it emit a non-terminating error and return empty -- and an empty
        # response means "save all" to this script. It would turn a declined run into a
        # saving one and spray an error block through the captured output, weakening the
        # very assertions these tests make. Piping a decline is the safe form.
        $out = 'n' | & powershell -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $script:repoRoot 'scripts\workspace-snapshot.ps1') @SnapArgs 2>&1
        return ($out | Out-String)
    } finally { $env:USERPROFILE = $saved }
}

It 'auto mode declines to shrink a pre-boot workspace.json, then saves once it postdates boot' {
    # One live session (a transcript fresh enough for the recency window) against a
    # pre-boot workspace.json holding THREE. Saving would drop the user from 3 to 1 --
    # exactly the post-blackout scheduled-tick loss the guard exists to prevent.
    $boot = Get-LastBootOrFallback
    $fake = New-FakeHome
    try {
        New-FakeTranscript -FakeHome $fake -Uuid 'aaaaaaaa-1111-2222-3333-444444444444' -Title 'Live one' -Modified (Get-Date) | Out-Null
        $ws = Write-FakeWorkspace -FakeHome $fake -Modified $boot.AddMinutes(-30) -Uuids @(
            'bbbbbbbb-1111-2222-3333-444444444444',
            'cccccccc-1111-2222-3333-444444444444',
            'dddddddd-1111-2222-3333-444444444444')
        $before = (Get-FileHash -LiteralPath $ws -Algorithm SHA256).Hash

        $text = Invoke-Snapshot -FakeHome $fake -SnapArgs @('--auto', '--no-history')
        Assert-True ($text -match '\[OPEN\]|\[F\]|\[OPEN\?\]') 'the fixture must produce a live row, or this test proves nothing'
        Assert-True ($text -match 'Not overwriting') 'auto must decline the shrinking write'
        Assert-True ($text -match 'holds 3 session\(s\); this run found only 1') 'the message must name both counts'
        Assert-Equal $before (Get-FileHash -LiteralPath $ws -Algorithm SHA256).Hash 'the pre-boot snapshot must survive'

        # Narrow, not a blanket refusal: once the file postdates the boot the guard
        # stops firing and the same shrinking write goes through.
        (Get-Item -LiteralPath $ws).LastWriteTime = (Get-Date)
        $text2 = Invoke-Snapshot -FakeHome $fake -SnapArgs @('--auto', '--no-history')
        Assert-True ($text2 -notmatch 'Not overwriting') 'a post-boot target must not be protected'
        Assert-True ($text2 -match 'Saved 1 session') 'the write must go through'
        Assert-True ($before -ne (Get-FileHash -LiteralPath $ws -Algorithm SHA256).Hash) 'the file must actually have changed'
    } finally { Remove-Item -LiteralPath $fake -Recurse -Force -ErrorAction SilentlyContinue }
}

It 'hydrates a snapshot-recorded Codex session whose rollout is outside every activity window' {
    # $codexRolloutById is filled from two ACTIVITY windows (live recency, and the
    # shutdown window). A snapshot records what was OPEN, so a Codex tab left idle
    # overnight has activity in neither and would be dropped unhydratable. The lazy
    # full index of ~/.codex/sessions is what rescues it -- so park the rollout well
    # outside both windows and require the [H] row to appear anyway.
    $boot = Get-LastBootOrFallback
    $fake = New-FakeHome
    try {
        $sid = '01a0760d-add4-72d2-ad5c-05467335623e'   # the id inside rollout-user.jsonl
        $sessDir = Join-Path $fake '.codex\sessions\2026\09\01'
        New-Item -ItemType Directory -Path $sessDir -Force | Out-Null
        $rollout = Join-Path $sessDir "rollout-2026-09-01T00-00-00-${sid}.jsonl"
        Copy-Item -LiteralPath (Join-Path $script:testsRoot 'fixtures\rollout-user.jsonl') -Destination $rollout -Force
        # 10 days before the boot: outside the default recency window AND outside
        # [shutdown-4h, shutdown+5m], so only the lazy index can find it.
        (Get-Item -LiteralPath $rollout).LastWriteTime = $boot.AddDays(-10)

        $ws = Join-Path $fake '.claude\workspace.json'
        [System.IO.File]::WriteAllText($ws,
            ('{ "created": "2026-01-01T00:00:00", "groups": [ { "name": "VTWO", "tabColor": "#111", "sessions": [ ' +
             '{ "sessionId": "' + $sid + '", "agent": "codex", "tabName": "VTWO: idle codex tab", "tier": "open", "modified": "2026-09-01T00:00:00" } ] } ] }'),
            [System.Text.Encoding]::ASCII)
        (Get-Item -LiteralPath $ws).LastWriteTime = $boot.AddMinutes(-30)

        $text = Invoke-Snapshot -FakeHome $fake -SnapArgs @('--history', '--agent', 'codex')
        Assert-True ($text -match 'cx .*\[H\] \(from snapshot\)') 'the idle Codex tab must be hydrated and shown as a snapshot-backed history row'
        Assert-True ($text -notmatch 'more pre-shutdown session\(s\) not shown') 'nothing should have been dropped'
    } finally { Remove-Item -LiteralPath $fake -Recurse -Force -ErrorAction SilentlyContinue }
}

It 'history mining refuses rows that were themselves saved from the history tier' {
    # A [H] row saved interactively lands in workspace.json as an ordinary session. Read
    # back on the next boot it would rank top (source=snapshot) and skip the trivial-
    # session demotion -- a guess laundered into evidence. Get-SnapshotHistoryIds must
    # drop it, leaving only the genuinely-open row.
    $env:WSS_LOAD_ONLY = '1'
    . (Join-Path $script:repoRoot 'scripts\workspace-snapshot.ps1')
    Remove-Item Env:\WSS_LOAD_ONLY -ErrorAction SilentlyContinue

    $fake = New-FakeHome
    try {
        $ws = Join-Path $fake '.claude\workspace.json'
        [System.IO.File]::WriteAllText($ws,
            ('{ "created": "2026-01-01T00:00:00", "groups": [ { "name": "Guard", "tabColor": "#111", "sessions": [ ' +
             '{ "sessionId": "eeeeeeee-1111-2222-3333-444444444444", "tabName": "real tab", "tier": "open", "modified": "2026-01-01T00:00:00" }, ' +
             '{ "sessionId": "ffffffff-1111-2222-3333-444444444444", "tabName": "laundered guess", "tier": "history", "modified": "2026-01-01T00:00:00" } ] } ] }'),
            [System.Text.Encoding]::ASCII)
        (Get-Item -LiteralPath $ws).LastWriteTime = [datetime]'2026-01-02T00:00:00'

        $recs = @(Get-SnapshotHistoryIds -WorkspaceFile $ws -LastBoot ([datetime]'2030-01-01'))
        Assert-Equal 1 $recs.Count 'only the non-history row may be mined'
        Assert-Equal 'eeeeeeee-1111-2222-3333-444444444444' $recs[0].sessionId
    } finally { Remove-Item -LiteralPath $fake -Recurse -Force -ErrorAction SilentlyContinue }
}
