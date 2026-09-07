# tests/run-tests.ps1
param([string]$Filter = '*')
$script:pass = 0
$script:fail = 0
$script:testsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:repoRoot  = Split-Path -Parent $script:testsRoot

function It {
    param([string]$Name, [scriptblock]$Body)
    if ($Name -notlike $Filter) { return }
    try {
        & $Body
        $script:pass++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } catch {
        $script:fail++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ("$Expected" -ne "$Actual") { throw "expected [$Expected] but got [$Actual] $Because" }
}
function Assert-True {
    param([bool]$Condition, [string]$Because = '')
    if (-not $Condition) { throw "expected true $Because" }
}
function Assert-Null {
    param($Value, [string]$Because = '')
    if ($null -ne $Value) { throw "expected null but got [$Value] $Because" }
}

Get-ChildItem -Path $script:testsRoot -Filter 'test-*.ps1' | Sort-Object Name | ForEach-Object {
    Write-Host ""
    Write-Host "$($_.BaseName)" -ForegroundColor Cyan
    . $_.FullName
}

Write-Host ""
Write-Host "  $script:pass passed, $script:fail failed" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $(if ($script:fail) { 1 } else { 0 })
