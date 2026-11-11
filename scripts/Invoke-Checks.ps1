#Requires -Version 7.2
<#
.SYNOPSIS
    Runs the same checks as the CI workflow: PSScriptAnalyzer, then the Pester tests.
.DESCRIPTION
    Needs Pester 5 and PSScriptAnalyzer:
        Install-Module Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99 -Scope CurrentUser
        Install-Module PSScriptAnalyzer -Scope CurrentUser
    The Microsoft Graph PowerShell SDK is not needed. Graph is mocked. When the SDK happens to be
    installed, one extra test group compares the mocks with the real cmdlet signatures.
    Exits with a non-zero code when anything fails.
#>
[CmdletBinding()]
param(
    [string]$TestResultPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Path $PSScriptRoot -Parent
$failed = $false

Import-Module Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99
Import-Module PSScriptAnalyzer

Write-Host '== PSScriptAnalyzer: module source (errors and warnings fail the run) ==' -ForegroundColor Cyan
$source = @(Invoke-ScriptAnalyzer -Path (Join-Path $root 'src') -Recurse -Severity Warning, Error)
$source | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 200 | Write-Host
if ($source.Count -gt 0) { $failed = $true; Write-Host "$($source.Count) finding(s) in src." -ForegroundColor Red }
else { Write-Host 'No findings in src.' -ForegroundColor Green }

Write-Host '== PSScriptAnalyzer: tests and scripts (fixtures may use globals and unused parameters) ==' -ForegroundColor Cyan
$relaxed = 'PSAvoidGlobalVars', 'PSReviewUnusedParameter', 'PSUseShouldProcessForStateChangingFunctions', 'PSUseSingularNouns', 'PSAvoidUsingWriteHost'
$others = @(foreach ($folder in 'tests', 'scripts') {
        Invoke-ScriptAnalyzer -Path (Join-Path $root $folder) -Recurse -Severity Warning, Error -ExcludeRule $relaxed
    })
$others | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 200 | Write-Host
if ($others.Count -gt 0) { $failed = $true; Write-Host "$($others.Count) finding(s) in tests or scripts." -ForegroundColor Red }
else { Write-Host 'No findings in tests or scripts.' -ForegroundColor Green }

Write-Host '== Pester ==' -ForegroundColor Cyan
$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $root 'tests'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Normal'
if ($TestResultPath) {
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputPath = $TestResultPath
    $configuration.TestResult.OutputFormat = 'NUnitXml'
}
$result = Invoke-Pester -Configuration $configuration
Write-Host ("Pester: {0} passed, {1} failed, {2} skipped." -f $result.PassedCount, $result.FailedCount, $result.SkippedCount)
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { $failed = $true }

if ($failed) { Write-Host 'Checks FAILED.' -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
