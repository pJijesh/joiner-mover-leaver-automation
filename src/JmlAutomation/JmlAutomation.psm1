# JmlAutomation root module.
# Loads private helpers first, then public commands, and exports only the public ones.
Set-StrictMode -Version Latest

$script:JmlModuleRoot = $PSScriptRoot
$script:JmlDefaultConfigPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../config'))
$script:JmlModuleVersion = '1.0.0'

foreach ($folder in 'Private', 'Public') {
    $path = Join-Path $PSScriptRoot $folder
    foreach ($file in Get-ChildItem -Path $path -Filter '*.ps1' -File | Sort-Object Name) {
        . $file.FullName
    }
}

$publicFunctions = Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File |
    ForEach-Object { $_.BaseName }
Export-ModuleMember -Function $publicFunctions
