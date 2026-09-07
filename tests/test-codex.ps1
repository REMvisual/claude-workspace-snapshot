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
It 'skips a bare closing tag left over from a split attachment' {
    # A closing tag like </image> has "/" where the general tag rule checks for a
    # tag-name character, so it must be explicitly allowed to fall through as
    # synthetic too, or it leaks as if it were the user's typed prompt.
    $p = Get-CodexFirstPrompt -Path (Join-Path $fx 'rollout-user.jsonl')
    Assert-True ($p -ne '</image>') 'closing tag should never be returned as the prompt'
    Assert-Equal 'juar making sure that we are using our deisgn mocup for proper design.' $p
}
It 'reads a rollout while codex holds it open for writing (live-session lock)' {
    # A real running codex.exe opens its rollout with FileAccess.ReadWrite and a
    # FileShare that still permits external readers, PROVIDED the reader also
    # requests FileShare.ReadWrite (verified against a real live rollout on this
    # machine: [System.IO.File]::ReadLines throws a sharing-violation IOException
    # against it, while File.Open(..., FileShare.ReadWrite|Delete) reads it fine).
    # This reproduces that exact lock shape on a throwaway temp file.
    $tmp = Join-Path $env:TEMP "wss-codex-lock-test-$([guid]::NewGuid()).jsonl"
    Copy-Item -LiteralPath (Join-Path $fx 'rollout-user.jsonl') -Destination $tmp
    $lockFs = [System.IO.File]::Open($tmp, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
    try {
        $meta = Get-CodexSessionMeta -Path $tmp
        Assert-Equal '01a0760d-add4-72d2-ad5c-05467335623e' $meta.sessionId
        $prompt = Get-CodexFirstPrompt -Path $tmp
        Assert-Equal 'juar making sure that we are using our deisgn mocup for proper design.' $prompt
    } finally {
        $lockFs.Dispose()
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
}
