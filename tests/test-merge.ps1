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
    $live = @(1..30 | ForEach-Object { New-Rec ("33333333-0000-0000-0000-{0:D12}" -f $_) })
    $r = Merge-SessionSets -Live $live -History @() -Cap 25
    Assert-Equal 0 $r.sessions.Count
    Assert-Equal 0 $r.truncated
}
It 'reads ids and tab names out of a pre-crash snapshot' {
    $recs = @(Get-SnapshotHistoryIds -WorkspaceFile (Join-Path $script:testsRoot 'fixtures\workspace-precrash.json') `
                                     -LastBoot ([datetime]'2030-01-01'))
    Assert-Equal 2 $recs.Count
    Assert-Equal 'snapshot' $recs[0].source
    Assert-True ([bool]$recs[0].tabName) 'tab name carried over'
}
It 'ignores a snapshot newer than the boot it is meant to predate' {
    $recs = @(Get-SnapshotHistoryIds -WorkspaceFile (Join-Path $script:testsRoot 'fixtures\workspace-precrash.json') `
                                     -LastBoot ([datetime]'2000-01-01'))
    Assert-Equal 0 $recs.Count
}
