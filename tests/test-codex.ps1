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

It 'reports a held lock as held and a free one as free' {
    $tmp = Join-Path $env:TEMP "wss-lock-$([guid]::NewGuid()).lock"
    Set-Content -LiteralPath $tmp -Value '' -Encoding ASCII
    try {
        Assert-Equal $false (Test-LockHeld -Path $tmp) 'nothing holding it yet'
        $fs = [System.IO.File]::Open($tmp, 'Open', 'ReadWrite', 'None')
        try { Assert-Equal $true (Test-LockHeld -Path $tmp) 'exclusive handle open' }
        finally { $fs.Close(); $fs.Dispose() }
        Assert-Equal $false (Test-LockHeld -Path $tmp) 'handle released'
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

It 'reports a missing lock file as not held' {
    Assert-Equal $false (Test-LockHeld -Path (Join-Path $env:TEMP 'wss-absent.lock'))
}

It 'ignores the coordination lock and non-uuid names' {
    $dir = Join-Path $env:TEMP "wss-locks-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try {
        # Hold real exclusive handles on both files to prove the zero result comes
        # from name filtering, not from unlocked-file state
        $coordFile = Join-Path $dir '.coordination.lock'
        $badNameFile = Join-Path $dir 'not-a-uuid.lock'
        Set-Content -LiteralPath $coordFile -Value '' -Encoding ASCII
        Set-Content -LiteralPath $badNameFile -Value '' -Encoding ASCII
        $fs1 = [System.IO.File]::Open($coordFile, 'Open', 'ReadWrite', 'None')
        $fs2 = [System.IO.File]::Open($badNameFile, 'Open', 'ReadWrite', 'None')
        try {
            if ($env:CODEX_DEBUG) { Write-Host "TEST: Calling Get-CodexHeldLockIds for dir: $dir" }
            $held = Get-CodexHeldLockIds -LockDir $dir
            if ($env:CODEX_DEBUG) { Write-Host "TEST: Got result count: $($held.Count), Type: $($held.GetType().Name)" }
            Assert-Equal 0 $held.Count
        } finally {
            $fs1.Close(); $fs1.Dispose()
            $fs2.Close(); $fs2.Dispose()
        }
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

It 'returns an array of zero for a lock directory with no held locks' {
    $dir = Join-Path $env:TEMP "wss-locks-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try {
        # Test raw return value without pre-wrapping in @()
        $result = Get-CodexHeldLockIds -LockDir $dir
        # Must be an array type, Count property must exist and equal 0
        Assert-Equal 0 $result.Count 'should return array with Count 0, not $null'
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

It 'returns an array with exactly one held lock containing the full uuid' {
    $dir = Join-Path $env:TEMP "wss-locks-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try {
        $lockId = '01a0760d-add4-72d2-ad5c-05467335623e'
        $lockFile = Join-Path $dir "$lockId.lock"
        Set-Content -LiteralPath $lockFile -Value '' -Encoding ASCII
        $fs = [System.IO.File]::Open($lockFile, 'Open', 'ReadWrite', 'None')
        try {
            # Test raw return value without pre-wrapping in @()
            $result = Get-CodexHeldLockIds -LockDir $dir
            Assert-Equal 1 $result.Count 'should return array with Count 1'
            # Discriminating assertion: under the bug, result[0] would be single char '0'
            Assert-Equal 36 $result[0].Length 'element [0] must be full 36-char uuid, not single char'
            Assert-Equal $lockId $result[0] 'element [0] must be the exact uuid'
        } finally {
            $fs.Close(); $fs.Dispose()
        }
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

It 'returns an array with exactly two held locks' {
    $dir = Join-Path $env:TEMP "wss-locks-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    try {
        $id1 = '01a0760d-add4-72d2-ad5c-05467335623e'
        $id2 = '01a077a2-ff9c-70b3-b3af-9d5303a501df'
        $file1 = Join-Path $dir "$id1.lock"
        $file2 = Join-Path $dir "$id2.lock"
        Set-Content -LiteralPath $file1 -Value '' -Encoding ASCII
        Set-Content -LiteralPath $file2 -Value '' -Encoding ASCII
        $fs1 = [System.IO.File]::Open($file1, 'Open', 'ReadWrite', 'None')
        $fs2 = [System.IO.File]::Open($file2, 'Open', 'ReadWrite', 'None')
        try {
            # Test raw return value without pre-wrapping in @()
            $result = Get-CodexHeldLockIds -LockDir $dir
            Assert-Equal 2 $result.Count 'should return array with Count 2'
            # Verify both ids are present
            $ids = @($result)
            Assert-Equal $true ($ids -contains $id1) 'should contain first uuid'
            Assert-Equal $true ($ids -contains $id2) 'should contain second uuid'
        } finally {
            $fs1.Close(); $fs1.Dispose()
            $fs2.Close(); $fs2.Dispose()
        }
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}
