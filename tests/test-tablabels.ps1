# tests/test-tablabels.ps1
# Set-TabLabels is the ONLY place the tool mutates tabName, and workspace-restore.ps1
# titles a restored Windows Terminal tab from tabName alone (it never reads summary).
# A regression here is therefore permanent and invisible: an earlier round of this work
# collapsed every title to "VTWO: VTWO". Fixtures are built inline so the test says the
# same thing on any machine, with no dependency on real tabs or real transcripts.
$env:WSS_LOAD_ONLY = '1'
. (Join-Path $script:repoRoot 'scripts\workspace-snapshot.ps1')
Remove-Item Env:\WSS_LOAD_ONLY -ErrorAction SilentlyContinue

# Only the fields Set-TabLabels actually reads or writes.
function New-Sess {
    param([string]$Id, [string]$Project, [string]$TabName, [string]$Tier = 'open')
    [pscustomobject]@{
        sessionId = $Id
        project   = $Project
        tier      = $Tier
        tabName   = $TabName
        tabLabel  = ''
    }
}

# Same normalization the tool applies when it builds the haystacks.
function New-Hay {
    param([string]$Text)
    return ($Text.ToLower() -replace '[^a-z0-9]', '')
}

It 'a tab named after nothing but its project labels but never overwrites tabName' {
    # The "VTWO: VTWO" regression. Adopting a project-only tab as the tabName throws
    # away the only description the session has, and restore cannot get it back.
    $s = New-Sess 'aaaaaaaa-0000-0000-0000-000000000001' 'VTWO' 'VTWO: Node graph design and color audit'
    $hay = @{ $s.sessionId = New-Hay 'VTWO Node graph design and color audit' }
    Set-TabLabels -Sessions @($s) -Tabs @('VTWO') -Haystacks $hay -StrongHaystacks $hay
    Assert-Equal 'VTWO' $s.tabLabel 'the tab is still recognised and shown as the label'
    Assert-Equal 'VTWO: Node graph design and color audit' $s.tabName 'tabName must survive a project-only tab'
}

It 'a tab already carrying its project prefix is not prefixed twice' {
    $s = New-Sess 'bbbbbbbb-0000-0000-0000-000000000002' 'VTWO' 'VTWO: Node graph design and color audit'
    $hay = @{ $s.sessionId = New-Hay 'VTWO Node graph design and color audit' }
    Set-TabLabels -Sessions @($s) -Tabs @('VTWO: Node graph') -Haystacks $hay -StrongHaystacks $hay
    Assert-Equal 'VTWO: Node graph' $s.tabLabel
    Assert-Equal 'VTWO: Node graph' $s.tabName 'an already-prefixed tab is adopted as-is'
    Assert-True ($s.tabName -notmatch 'VTWO: VTWO') 'the project prefix must never stack'
}

It 'an unprefixed tab gets exactly one project prefix' {
    $s = New-Sess 'cccccccc-0000-0000-0000-000000000003' 'VTWO' 'VTWO: Node graph design and color audit'
    $hay = @{ $s.sessionId = New-Hay 'VTWO Node graph design and color audit' }
    Set-TabLabels -Sessions @($s) -Tabs @('Node graph') -Haystacks $hay -StrongHaystacks $hay
    Assert-Equal 'Node graph' $s.tabLabel
    Assert-Equal 'VTWO: Node graph' $s.tabName
}

It 'a tab that matches two sessions equally is spent on exactly one of them' {
    # One tab per session is the whole safety property: the greedy assignment marks the
    # tab used after the first winner, so the runner-up keeps its original tabName rather
    # than being handed a title that describes someone else's session. Which of the two
    # wins is not asserted -- Sort-Object is not documented as stable on Windows
    # PowerShell 5.1 -- but that exactly ONE wins and the other is untouched is.
    $a = New-Sess 'dddddddd-0000-0000-0000-000000000004' 'alphaone' 'alphaone: first session'
    $b = New-Sess 'eeeeeeee-0000-0000-0000-000000000005' 'betatwo'  'betatwo: second session'
    $shared = New-Hay 'Deformer campaign review'
    $hay = @{ $a.sessionId = $shared; $b.sessionId = $shared }
    Set-TabLabels -Sessions @($a, $b) -Tabs @('Deformer campaign review') -Haystacks $hay -StrongHaystacks $hay

    $labeled = @(@($a, $b) | Where-Object { $_.tabLabel })
    Assert-Equal 1 $labeled.Count 'an ambiguous tab must be spent on one session, never both'
    Assert-Equal 'Deformer campaign review' $labeled[0].tabLabel

    $untouched = @(@($a, $b) | Where-Object { -not $_.tabLabel })
    Assert-Equal 1 $untouched.Count
    $expected = 'betatwo: second session'
    if ($untouched[0].sessionId -eq $a.sessionId) { $expected = 'alphaone: first session' }
    Assert-Equal $expected $untouched[0].tabName 'the losing session keeps its own original tabName'
    Assert-True ($untouched[0].tabName -notmatch 'Deformer') 'the losing session never inherits the winner title'
}

It 'returns the cleaned tab list that the summary banner prints' {
    # The banner ("Open terminal tabs (N): ...") is fed by the cleaned list, so the
    # function has to hand it back: an extraction that kept the list private silently
    # deleted that whole line from the tool's output.
    $s = New-Sess 'ffffffff-0000-0000-0000-000000000006' 'VTWO' 'VTWO: Node graph design and color audit'
    $hay = @{ $s.sessionId = New-Hay 'VTWO Node graph design and color audit' }
    $clean = @(Set-TabLabels -Sessions @($s) `
        -Tabs @('VTWO', 'C:\Standalone\VTWO', 'pwsh /usr/bin', ('busy' + [char]0x07)) `
        -Haystacks $hay -StrongHaystacks $hay)
    Assert-Equal 2 $clean.Count 'path-like tabs are dropped, real titles are kept'
    Assert-Equal 'VTWO' $clean[0]
    Assert-Equal 'busy' $clean[1] 'spinner glyphs are stripped, not the whole title'
}

It 'Get-EditDistance keeps the transposed rename the rescue pass was written for' {
    # The comment on the rescue pass cites this pair: "defromer" -> "deformers" is one
    # transposition plus one insert, and the rescue accepts a distance of 2 or less.
    Assert-True ((Get-EditDistance 'defromer' 'deformers') -le 2) 'defromer/deformers must stay inside the rescue threshold'
    Assert-Equal 2 (Get-EditDistance 'defromer' 'deformers')
    # ...without the threshold being so loose that unrelated project names pass it.
    Assert-True ((Get-EditDistance 'deformers' 'raytracer') -gt 2) 'unrelated names must stay outside the threshold'
}
