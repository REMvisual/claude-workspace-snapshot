It 'snapshot script loads without executing' {
    $env:WSS_LOAD_ONLY = '1'
    try {
        . (Join-Path $script:repoRoot 'scripts\workspace-snapshot.ps1')
        Assert-True ([bool](Get-Command Get-SafeTabName -ErrorAction SilentlyContinue)) 'Get-SafeTabName defined'
        Assert-True ([bool](Get-Command Get-ProjectColor -ErrorAction SilentlyContinue)) 'Get-ProjectColor defined'
        # $liveIds is only ever assigned inside STEP 1 (well after the guard) -- if the
        # guard failed to fire, dot-sourcing would have run STEP 1 and this would be set.
        Assert-True (-not (Test-Path variable:\liveIds)) 'STEP 1 must not have run under WSS_LOAD_ONLY'
    } finally { Remove-Item Env:\WSS_LOAD_ONLY -ErrorAction SilentlyContinue }
}
It 'restore script loads without executing' {
    $env:WSS_LOAD_ONLY = '1'
    try {
        . (Join-Path $script:repoRoot 'scripts\workspace-restore.ps1')
        Assert-True ([bool](Get-Command Get-SafeTabName -ErrorAction SilentlyContinue)) 'Get-SafeTabName defined'
        # $rawGroups is only ever assigned after the guard (workspace file read + parsed).
        # If the guard failed to fire, dot-sourcing would have run that far and this would be set.
        Assert-True (-not (Test-Path variable:\rawGroups)) 'workspace parsing must not have run under WSS_LOAD_ONLY'
    } finally { Remove-Item Env:\WSS_LOAD_ONLY -ErrorAction SilentlyContinue }
}
It 'uuid regex is available without running the script' {
    $env:WSS_LOAD_ONLY = '1'
    try {
        . (Join-Path $script:repoRoot 'scripts\workspace-snapshot.ps1')
        Assert-True ('01a0760d-add4-72d2-ad5c-05467335623e' -match "^$uuidRe$") 'uuidRe defined and matching'
        Assert-True (-not ('not-a-uuid' -match "^$uuidRe$")) 'uuidRe actually rejects non-uuids'
    } finally { Remove-Item Env:\WSS_LOAD_ONLY -ErrorAction SilentlyContinue }
}
