# tests/test-restore.ps1
$env:WSS_LOAD_ONLY = '1'
. (Join-Path $script:repoRoot 'scripts\workspace-restore.ps1')
Remove-Item Env:\WSS_LOAD_ONLY -ErrorAction SilentlyContinue

It 'builds the Claude resume command' {
    Assert-Equal 'claude --resume abc' (Get-ResumeCommand -Agent 'claude' -SessionId 'abc')
}
It 'builds the Codex resume command' {
    Assert-Equal 'codex resume abc' (Get-ResumeCommand -Agent 'codex' -SessionId 'abc')
}
It 'refuses an unknown agent' {
    Assert-Null (Get-ResumeCommand -Agent 'pwn & calc' -SessionId 'abc')
}
It 'dry-run emits one resume verb per valid agent and skips the hostile row' {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $script:repoRoot 'scripts\workspace-restore.ps1') `
        --dry-run --all --file (Join-Path $script:testsRoot 'fixtures\workspace-mixed.json') 2>&1 | Out-String
    Assert-True ($out -match 'claude --resume') 'claude verb present'
    Assert-True ($out -match 'codex resume')    'codex verb present'
    Assert-True ($out -notmatch 'calc')         'hostile agent never reaches the command line'
    Assert-True ($out -match '2 tab\(s\)')      'exactly two tabs planned'
}
