# tests/test-claude-record.ps1
# Get-ClaudeSessionRecord is the single reader behind the tool's core path: both the
# live pass and the pre-shutdown history tier hydrate through it. Fixtures are built
# here rather than read from the real ~/.claude, so the test says the same thing on
# any machine.
$env:WSS_LOAD_ONLY = '1'
. (Join-Path $script:repoRoot 'scripts\workspace-snapshot.ps1')
Remove-Item Env:\WSS_LOAD_ONLY -ErrorAction SilentlyContinue

function New-TranscriptFile {
    param([string[]]$Lines)
    $dir = Join-Path $env:TEMP ("wss-rec-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir '99999999-aaaa-bbbb-cccc-dddddddddddd.jsonl'
    [System.IO.File]::WriteAllLines($path, $Lines, (New-Object System.Text.UTF8Encoding($false)))
    return (Get-Item -LiteralPath $path)
}

It 'builds a record with the expected fields from a normal transcript' {
    $f = New-TranscriptFile @(
        '{"type":"user","cwd":"C:\\Fake\\WidgetShop","gitBranch":"feature-x","slug":"widget-shop","message":{"role":"user","content":"rebuild the widget cache please"}}',
        '{"type":"ai-title","aiTitle":"Widget cache rebuild"}'
    )
    try {
        $r = Get-ClaudeSessionRecord -SessionId $f.BaseName -JsonlFile $f -SummaryLookup @{} -Tier 'recent' -Source 'file'
        Assert-True ($null -ne $r) 'a normal transcript must produce a record'
        $rec = $r.record
        Assert-Equal $f.BaseName $rec.sessionId
        Assert-Equal 'claude' $rec.agent
        Assert-Equal 'C:\Fake\WidgetShop' $rec.projectPath
        Assert-Equal 'WidgetShop' $rec.project
        Assert-Equal 'WidgetShop' $rec.group
        # ai-title outranks the first prompt as the display name
        Assert-Equal 'Widget cache rebuild' $rec.summary
        Assert-Equal 'WidgetShop: Widget cache rebuild' $rec.tabName
        Assert-Equal 'feature-x' $rec.gitBranch
        Assert-Equal 'widget-shop' $rec.slug
        Assert-Equal 'recent' $rec.tier
        Assert-Equal 'file' $rec.source
        Assert-Equal (Get-ProjectColor 'WidgetShop') $rec.tabColor
        Assert-Equal 'rebuild the widget cache please' $rec.firstPrompt
        Assert-Equal '' $rec.tabLabel
        # modified must round-trip: the tier sort re-Parses it
        $parsed = [datetime]::MinValue
        Assert-True ([datetime]::TryParse($rec.modified, [ref]$parsed)) 'modified must be parseable'
        # the haystacks tab-title matching depends on are stripped to [a-z0-9]
        Assert-True ($r.haystack -match '^[a-z0-9]*$') 'haystack is normalized'
        Assert-True ($r.haystack.Contains('widgetcacherebuild')) 'haystack carries the title'
        Assert-True ($r.haystack.Contains('rebuildthewidgetcacheplease')) 'haystack carries the first prompt'
        Assert-True (-not $r.strongHaystack.Contains('rebuildthewidgetcacheplease')) 'strongHaystack must exclude the first prompt'
    } finally { Remove-Item -LiteralPath $f.DirectoryName -Recurse -Force -ErrorAction SilentlyContinue }
}

It 'returns null for a sidechain transcript' {
    $f = New-TranscriptFile @(
        '{"type":"user","isSidechain":true,"cwd":"C:\\Fake\\WidgetShop","message":{"role":"user","content":"subagent work"}}'
    )
    try {
        Assert-Null (Get-ClaudeSessionRecord -SessionId $f.BaseName -JsonlFile $f -SummaryLookup @{} -Tier 'recent' -Source 'file')
    } finally { Remove-Item -LiteralPath $f.DirectoryName -Recurse -Force -ErrorAction SilentlyContinue }
}

It 'returns null when there is no cwd or no real prompt' {
    # Only a slash-command record: skipped as not a real prompt, so nothing to build from.
    $f = New-TranscriptFile @(
        '{"type":"user","cwd":"C:\\Fake\\WidgetShop","message":{"role":"user","content":"<command-name>/clear</command-name>"}}'
    )
    try {
        Assert-Null (Get-ClaudeSessionRecord -SessionId $f.BaseName -JsonlFile $f -SummaryLookup @{} -Tier 'recent' -Source 'file')
    } finally { Remove-Item -LiteralPath $f.DirectoryName -Recurse -Force -ErrorAction SilentlyContinue }
}

It 'returns null for a missing file rather than throwing' {
    Assert-Null (Get-ClaudeSessionRecord -SessionId '99999999-aaaa-bbbb-cccc-dddddddddddd' -JsonlFile $null -SummaryLookup @{} -Tier 'history' -Source 'snapshot')
}

It 'falls back to the indexed summary when there is no ai-title' {
    $f = New-TranscriptFile @(
        '{"type":"user","cwd":"C:\\Fake\\WidgetShop","message":{"role":"user","content":"rebuild the widget cache please"}}'
    )
    try {
        $lookup = @{ "$($f.BaseName)" = 'Indexed summary wins over the prompt' }
        $r = Get-ClaudeSessionRecord -SessionId $f.BaseName -JsonlFile $f -SummaryLookup $lookup -Tier 'history' -Source 'snapshot'
        Assert-True ($null -ne $r) 'record built'
        Assert-Equal 'Indexed summary wins over the prompt' $r.record.summary
        Assert-Equal 'history' $r.record.tier
        Assert-Equal 'snapshot' $r.record.source
    } finally { Remove-Item -LiteralPath $f.DirectoryName -Recurse -Force -ErrorAction SilentlyContinue }
}
