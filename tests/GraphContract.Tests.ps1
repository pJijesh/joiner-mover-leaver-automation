# Compares the signature-only Graph stubs used by the other tests with the real Microsoft Graph
# PowerShell SDK. It is skipped when the SDK is not installed, so the rest of the suite never needs it.
BeforeDiscovery {
    $script:SdkModules = 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Users', 'Microsoft.Graph.Users.Actions', 'Microsoft.Graph.Groups', 'Microsoft.Graph.Identity.SignIns'
    $script:SdkPresent = @($script:SdkModules | Where-Object { Get-Module -ListAvailable -Name $_ }).Count -eq $script:SdkModules.Count
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Helpers/GraphStubs.ps1'), [ref]$null, [ref]$null)
    $script:StubCases = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object {
            @{
                Name       = ($_.Name -replace '^global:', '')
                Parameters = @($_.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            }
        })
}

BeforeAll {
    $names = 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Users', 'Microsoft.Graph.Users.Actions', 'Microsoft.Graph.Groups', 'Microsoft.Graph.Identity.SignIns'
    $script:SdkLoaded = @($names | ForEach-Object { Import-Module -Name $_ -PassThru -ErrorAction SilentlyContinue })
}

AfterAll {
    $script:SdkLoaded | Where-Object { $_ } | Remove-Module -Force -ErrorAction SilentlyContinue
}

Describe 'Graph stubs match the Microsoft Graph PowerShell SDK' -Skip:(-not $script:SdkPresent) {
    It '<Name> exists and accepts every parameter the stub declares' -ForEach $script:StubCases {
        $command = $script:SdkLoaded | ForEach-Object { $_.ExportedCommands[$Name] } | Where-Object { $_ } | Select-Object -First 1
        $command | Should -Not -BeNullOrEmpty -Because "the module calls $Name"
        foreach ($parameter in $Parameters) {
            $command.Parameters.Keys | Should -Contain $parameter -Because "$Name -$parameter is used by the module"
        }
    }
}
