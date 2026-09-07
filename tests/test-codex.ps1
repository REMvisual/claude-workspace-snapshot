# tests/test-codex.ps1
$env:WSS_LOAD_ONLY = '1'
. (Join-Path $script:repoRoot 'scripts\workspace-snapshot.ps1')
Remove-Item Env:\WSS_LOAD_ONLY -ErrorAction SilentlyContinue
$fx = Join-Path $script:testsRoot 'fixtures'

It 'reads session_meta from a user thread' {
    $m = Get-CodexSessionMeta -Path (Join-Path $fx 'rollout-user.jsonl')
    Assert-Equal '01a0760d-add4-72d2-ad5c-05467335623e' $m.sessionId
    Assert-Equal 'C:\Standalone\VTWO' $m.cwd
}
It 'rejects a subagent thread' {
    Assert-Null (Get-CodexSessionMeta -Path (Join-Path $fx 'rollout-subagent.jsonl'))
}
It 'returns null for a missing file' {
    Assert-Null (Get-CodexSessionMeta -Path (Join-Path $fx 'does-not-exist.jsonl'))
}
It 'takes the newest thread_name per id' {
    $map = Get-CodexTitleMap -IndexPath (Join-Path $fx 'session_index.jsonl')
    Assert-Equal 'Confirm approved mockup usage plan' $map['01a0760d-add4-72d2-ad5c-05467335623e'].name
    Assert-Equal 'Explain missing YOLO label' $map['01a0760a-4f82-7020-b2f2-79db0b9bb0fe'].name
}
It 'returns an empty map for a missing index' {
    Assert-Equal 0 (Get-CodexTitleMap -IndexPath (Join-Path $fx 'nope.jsonl')).Count
}
It 'skips synthetic AGENTS.md preamble and finds the typed prompt' {
    $p = Get-CodexFirstPrompt -Path (Join-Path $fx 'rollout-user.jsonl')
    Assert-Equal 'juar making sure that we are using our deisgn mocup for proper design.' $p
}
