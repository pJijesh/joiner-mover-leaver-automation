function Get-JmlProperty {
    <#
    .SYNOPSIS
        Reads a property from a Graph SDK object, hashtable or custom object without throwing under strict mode.
    .DESCRIPTION
        Graph SDK responses expose some values as typed properties and others only inside
        AdditionalProperties. This helper checks both, case-insensitively, and returns a default
        when the value is absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowNull()]$InputObject,
        [Parameter(Mandatory, Position = 1)][string]$Name,
        [Parameter(Position = 2)]$Default = $null
    )

    if ($null -eq $InputObject) { return $Default }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ("$key" -ieq $Name) { return $InputObject[$key] }
        }
        return $Default
    }

    $property = $InputObject.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($property) { return $property.Value }

    $additional = $InputObject.PSObject.Properties | Where-Object { $_.Name -eq 'AdditionalProperties' } | Select-Object -First 1
    if ($additional -and $additional.Value -is [System.Collections.IDictionary]) {
        foreach ($key in $additional.Value.Keys) {
            if ("$key" -ieq $Name) { return $additional.Value[$key] }
        }
    }
    return $Default
}
