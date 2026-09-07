$env:WSS_LOAD_ONLY = '1'
. (Join-Path $script:repoRoot 'scripts\workspace-snapshot.ps1')
Remove-Item Env:\WSS_LOAD_ONLY -ErrorAction SilentlyContinue

$real6008 = [byte[]](234,7,9,0,0,0,6,0,9,0,5,0,0,0,148,1,
                     234,7,9,0,0,0,6,0,16,0,5,0,0,0,148,1,
                     96,9,0,0,60,0,0,0,1,0,0,0,96,9,0,0,1,0,0,0,176,4,0,0,1,0,0,0,5,0,0,0)

It 'decodes the real 6008 SYSTEMTIME payload as local time' {
    $t = ConvertFrom-SystemTimeBytes -Bytes $real6008 -Offset 0
    Assert-Equal '2026-09-06 09:05:00.404' $t.ToString('yyyy-MM-dd HH:mm:ss.fff')
}
It 'rejects a too-short buffer' {
    Assert-Null (ConvertFrom-SystemTimeBytes -Bytes ([byte[]](1,2,3)) -Offset 0)
}
It 'rejects an implausible year' {
    $bad = [byte[]](0,0, 9,0, 0,0, 6,0, 9,0, 5,0, 0,0, 0,0)
    Assert-Null (ConvertFrom-SystemTimeBytes -Bytes $bad -Offset 0)
}
It 'prefers the 6008 payload over its own TimeCreated' {
    $boot = [datetime]'2026-09-06 09:50:10'
    $ev = [pscustomobject]@{ Id = 6008; TimeCreated = [datetime]'2026-09-06 09:50:32'
                             Properties = @(0,0,0,0,0,0,0,[pscustomobject]@{ Value = $real6008 }) }
    $r = Resolve-LastShutdown -LastBoot $boot -Events @($ev)
    Assert-Equal 'unexpected' $r.kind
    Assert-Equal '2026-09-06 09:05:00' $r.time.ToString('yyyy-MM-dd HH:mm:ss')
}
It 'uses TimeCreated for a clean shutdown' {
    $boot = [datetime]'2026-09-02 10:30:00'
    $ev = [pscustomobject]@{ Id = 6006; TimeCreated = [datetime]'2026-09-02 10:22:55'; Properties = @() }
    $r = Resolve-LastShutdown -LastBoot $boot -Events @($ev)
    Assert-Equal 'clean' $r.kind
    Assert-Equal '2026-09-02 10:22:55' $r.time.ToString('yyyy-MM-dd HH:mm:ss')
}
It 'ignores Event 41 for timing but keeps the latest valid marker' {
    $boot = [datetime]'2026-09-06 09:50:10'
    $id41 = [pscustomobject]@{ Id = 41; TimeCreated = [datetime]'2026-09-06 09:50:16'
                               Properties = @(0,0,0,0,0,0,0,[pscustomobject]@{ Value = [uint32]0 }) }
    $clean = [pscustomobject]@{ Id = 6006; TimeCreated = [datetime]'2026-09-02 10:22:55'; Properties = @() }
    $r = Resolve-LastShutdown -LastBoot $boot -Events @($id41, $clean)
    Assert-Equal 'clean' $r.kind
    Assert-Equal '2026-09-02 10:22:55' $r.time.ToString('yyyy-MM-dd HH:mm:ss')
}
It 'falls back to boot time when no marker is usable' {
    $boot = [datetime]'2026-09-06 09:50:10'
    $r = Resolve-LastShutdown -LastBoot $boot -Events @()
    Assert-Equal 'assumed' $r.kind
    Assert-Equal $boot $r.time
}
It 'ignores markers at or after boot' {
    $boot = [datetime]'2026-09-06 09:50:10'
    $ev = [pscustomobject]@{ Id = 6006; TimeCreated = [datetime]'2026-09-06 11:00:00'; Properties = @() }
    Assert-Equal 'assumed' (Resolve-LastShutdown -LastBoot $boot -Events @($ev)).kind
}
