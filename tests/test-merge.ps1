# tests/test-merge.ps1
$env:WSS_LOAD_ONLY = '1'
. (Join-Path $script:repoRoot 'scripts\workspace-snapshot.ps1')
Remove-Item Env:\WSS_LOAD_ONLY -ErrorAction SilentlyContinue

function New-Rec {
    param($Id, $Source = 'file', $Modified = '2026-09-06T08:00:00', $Msgs = 10)
    [pscustomobject]@{ sessionId = $Id; source = $Source; modified = $Modified; messageCount = $Msgs }
}

It 'drops history rows that are already live' {
    $live = @(New-Rec 'aaaaaaaa-0000-0000-0000-000000000001')
    $hist = @(New-Rec 'aaaaaaaa-0000-0000-0000-000000000001'), (New-Rec 'bbbbbbbb-0000-0000-0000-000000000002')
    $r = Merge-SessionSets -Live $live -History $hist -Cap 25
    Assert-Equal 1 $r.sessions.Count
    Assert-Equal 'bbbbbbbb-0000-0000-0000-000000000002' $r.sessions[0].sessionId
}
It 'dedupes repeats inside the history set' {
    $hist = @(New-Rec 'cccccccc-0000-0000-0000-000000000003'), (New-Rec 'cccccccc-0000-0000-0000-000000000003')
    Assert-Equal 1 (Merge-SessionSets -Live @() -History $hist -Cap 25).sessions.Count
}
It 'ranks snapshot-backed rows above activity-only rows' {
    $hist = @(New-Rec 'dddddddd-0000-0000-0000-000000000004' 'file' '2026-09-06T09:00:00'),
            (New-Rec 'eeeeeeee-0000-0000-0000-000000000005' 'snapshot' '2026-09-06T07:00:00')
    $r = Merge-SessionSets -Live @() -History $hist -Cap 25
    Assert-Equal 'eeeeeeee-0000-0000-0000-000000000005' $r.sessions[0].sessionId
}
It 'ranks trivial sessions last' {
    $hist = @(New-Rec 'ffffffff-0000-0000-0000-000000000006' 'file' '2026-09-06T09:00:00' 1),
            (New-Rec '11111111-0000-0000-0000-000000000007' 'file' '2026-09-06T08:00:00' 40)
    $r = Merge-SessionSets -Live @() -History $hist -Cap 25
    Assert-Equal '11111111-0000-0000-0000-000000000007' $r.sessions[0].sessionId
}
It 'caps history rows and reports the remainder' {
    $hist = @(1..30 | ForEach-Object { New-Rec ("22222222-0000-0000-0000-{0:D12}" -f $_) })
    $r = Merge-SessionSets -Live @() -History $hist -Cap 25
    Assert-Equal 25 $r.sessions.Count
    Assert-Equal 5 $r.truncated
}
It 'never caps live rows' {
    # 30 live rows plus 5 DISTINCT history rows, capped tightly at 3: proves the cap
    # and the truncation count are driven purely by History, and that no live row
    # can ever surface in the result -- a History-only-empty fixture cannot prove this,
    # since an empty pipeline reads as "0 sessions" for the wrong reason.
    $live = @(1..30 | ForEach-Object { New-Rec ("33333333-0000-0000-0000-{0:D12}" -f $_) })
    $hist = @(1..5 | ForEach-Object { New-Rec ("44444444-0000-0000-0000-{0:D12}" -f $_) })
    $r = Merge-SessionSets -Live $live -History $hist -Cap 3
    Assert-Equal 3 $r.sessions.Count
    Assert-Equal 2 $r.truncated
    $liveIds = @($live | ForEach-Object { $_.sessionId })
    $overlap = @($r.sessions | Where-Object { $liveIds -contains $_.sessionId })
    Assert-Equal 0 $overlap.Count 'no live id should ever appear in the merged history result'
}
It 'reads ids and tab names out of a pre-crash snapshot' {
    $recs = @(Get-SnapshotHistoryIds -WorkspaceFile (Join-Path $script:testsRoot 'fixtures\workspace-precrash.json') `
                                     -LastBoot ([datetime]'2030-01-01'))
    Assert-Equal 2 $recs.Count
    Assert-Equal 'snapshot' $recs[0].source
    Assert-True ([bool]$recs[0].tabName) 'tab name carried over'
    # Identify each record by sessionId rather than assuming index order.
    $noAgentField = $recs | Where-Object { $_.sessionId -eq 'a1b2c3d4-e5f6-7890-abcd-ef1234567890' }
    $codexField   = $recs | Where-Object { $_.sessionId -eq '01a0760d-add4-72d2-ad5c-05467335623e' }
    Assert-Equal 'claude' $noAgentField.agent 'a session with no agent key defaults to claude'
    Assert-Equal 'codex' $codexField.agent 'a session with agent:codex carries it through'
}
It 'ignores a snapshot newer than the boot it is meant to predate' {
    $recs = @(Get-SnapshotHistoryIds -WorkspaceFile (Join-Path $script:testsRoot 'fixtures\workspace-precrash.json') `
                                     -LastBoot ([datetime]'2000-01-01'))
    Assert-Equal 0 $recs.Count
}
It 'stops at the newest snapshot that yields sessions and never surfaces older-only ids' {
    # Two candidate files: a newer primary workspace.json and an older backup, each
    # with a session id that appears in ONLY that one file. Their LastWriteTime is
    # set explicitly here (on temp files, never on the committed fixture) so the
    # newest-first / stop-on-first-success rule in Get-SnapshotHistoryIds is exercised.
    $tmp = Join-Path $env:TEMP ("wss-hist-test-" + [guid]::NewGuid().ToString('N'))
    $backupDir = Join-Path $tmp 'workspace-backups'
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    try {
        $newerFile = Join-Path $tmp 'workspace.json'
        $olderFile = Join-Path $backupDir 'workspace-old.json'

        $newerJson = '{ "created": "2026-09-06T09:00:00", "groups": [ { "name": "g", "tabColor": "#111", "sessions": [ { "sessionId": "55555555-0000-0000-0000-000000000001", "tabName": "newer-session", "modified": "2026-09-06T09:00:00" } ] } ] }'
        $olderJson = '{ "created": "2026-09-01T09:00:00", "groups": [ { "name": "g", "tabColor": "#111", "sessions": [ { "sessionId": "66666666-0000-0000-0000-000000000002", "tabName": "older-only-session", "modified": "2026-09-01T09:00:00" } ] } ] }'
        [System.IO.File]::WriteAllText($newerFile, $newerJson, [System.Text.Encoding]::ASCII)
        [System.IO.File]::WriteAllText($olderFile, $olderJson, [System.Text.Encoding]::ASCII)

        (Get-Item -LiteralPath $newerFile).LastWriteTime = [datetime]'2026-09-06T09:00:00'
        (Get-Item -LiteralPath $olderFile).LastWriteTime = [datetime]'2026-09-01T09:00:00'

        $recs = @(Get-SnapshotHistoryIds -WorkspaceFile $newerFile -LastBoot ([datetime]'2030-01-01'))
        Assert-Equal 1 $recs.Count
        Assert-Equal '55555555-0000-0000-0000-000000000001' $recs[0].sessionId
        $olderOnly = @($recs | Where-Object { $_.sessionId -eq '66666666-0000-0000-0000-000000000002' })
        Assert-Equal 0 $olderOnly.Count 'an id that exists only in an older backup must not surface once the newer file has yielded sessions'
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

It 'auto mode leaves workspace.json untouched when only history is found' {
    # Self-contained "history-only" world: a fake USERPROFILE whose ~/.claude holds one
    # pre-boot workspace.json naming one transcript that is too old to count as recent.
    # Real claude.exe processes on the box still get detected, but their session ids do
    # not exist under this projects dir, so the LIVE set is genuinely empty and the only
    # row the run can produce is a hydrated history row. Asserting on the file hash (not
    # on tiers) is what actually proves the invariant, and this fixture makes that
    # assertion deterministic -- no dependency on whether a Codex tab happens to be open.
    $boot = $null
    try { $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch {}
    if (-not $boot) { $boot = (Get-Date).AddHours(-3) }

    $fake = Join-Path $env:TEMP ("wss-auto-" + [guid]::NewGuid().ToString('N'))
    $proj = Join-Path $fake '.claude\projects\C--Fake-HistOnly'
    New-Item -ItemType Directory -Path $proj -Force | Out-Null
    $savedProfile = $env:USERPROFILE
    try {
        $uuid  = '77777777-1111-2222-3333-444444444444'
        $jsonl = Join-Path $proj "$uuid.jsonl"
        [System.IO.File]::WriteAllLines($jsonl, @(
            '{"type":"user","cwd":"C:\\Fake\\HistOnly","gitBranch":"master","message":{"role":"user","content":"please rebuild the widget cache"}}',
            '{"type":"ai-title","aiTitle":"Widget cache rebuild"}'
        ), (New-Object System.Text.UTF8Encoding($false)))
        (Get-Item -LiteralPath $jsonl).LastWriteTime = $boot.AddHours(-2)

        $ws = Join-Path $fake '.claude\workspace.json'
        [System.IO.File]::WriteAllText($ws,
            ('{ "created": "2026-01-01T00:00:00", "groups": [ { "name": "HistOnly", "tabColor": "#111111", "sessions": [ { "sessionId": "' +
             $uuid + '", "agent": "claude", "tabName": "HistOnly: Widget cache rebuild", "tabColor": "#111111", "modified": "2026-01-01T00:00:00" } ] } ] }'),
            [System.Text.Encoding]::ASCII)
        (Get-Item -LiteralPath $ws).LastWriteTime = $boot.AddMinutes(-30)

        $before = (Get-FileHash -LiteralPath $ws -Algorithm SHA256).Hash

        $env:USERPROFILE = $fake
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:repoRoot 'scripts\workspace-snapshot.ps1') `
            --auto --history --agent claude 2>&1
        $env:USERPROFILE = $savedProfile

        $text = ($out | Out-String)
        Assert-True ($text -match '\[H\]') 'the fixture must actually produce a history row, or this test proves nothing'
        Assert-True ($text -match 'only pre-shutdown history found') 'auto must report that it saved nothing'
        $after = (Get-FileHash -LiteralPath $ws -Algorithm SHA256).Hash
        Assert-Equal $before $after 'auto must not persist inferred rows'
    } finally {
        $env:USERPROFILE = $savedProfile
        Remove-Item -LiteralPath $fake -Recurse -Force -ErrorAction SilentlyContinue
    }
}
