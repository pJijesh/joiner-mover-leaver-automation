# Shared test bootstrap. Dot-sourced from BeforeAll in every test file.
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
. (Join-Path $PSScriptRoot 'Helpers/GraphStubs.ps1')
. (Join-Path $PSScriptRoot 'Helpers/FakeTenant.ps1')
Get-Module JmlAutomation | Remove-Module -Force
Import-Module (Join-Path $script:RepoRoot 'src/JmlAutomation/JmlAutomation.psd1') -Force
$script:ConfigPath = Join-Path $script:RepoRoot 'config'

function New-TestPaths {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("jml-test-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $root -Force
    [pscustomobject]@{ Root = $root; Audit = (Join-Path $root 'audit.jsonl'); Output = (Join-Path $root 'out') }
}

function Read-TestAudit {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    @(Get-Content -LiteralPath $Path | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}
