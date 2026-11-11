function New-JmlPassword {
    <#
    .SYNOPSIS
        Generates a random one-time password and returns it as a SecureString.
    .DESCRIPTION
        Uses the operating system cryptographic random number generator. The password contains
        upper case, lower case, digits and symbols, and avoids look-alike characters. It is built
        character by character into a SecureString so it never exists as a long-lived string
        variable, and it is never written to the audit log.
    #>
    [CmdletBinding()]
    [OutputType([System.Security.SecureString])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Generates an in-memory value only.')]
    param([ValidateRange(16, 64)][int]$Length = 20)

    $sets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnopqrstuvwxyz',
        '23456789',
        '!@#$%^&*-_=+?'
    )
    $all = -join $sets
    $rng = [System.Security.Cryptography.RandomNumberGenerator]

    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($set in $sets) {
        # Two characters from each class guarantees complexity.
        1..2 | ForEach-Object { $chars.Add($set[$rng::GetInt32($set.Length)]) }
    }
    while ($chars.Count -lt $Length) { $chars.Add($all[$rng::GetInt32($all.Length)]) }

    # Fisher-Yates shuffle so the guaranteed characters are not always first.
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = $rng::GetInt32($i + 1)
        $swap = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $swap
    }

    $secure = [System.Security.SecureString]::new()
    foreach ($c in $chars) { $secure.AppendChar($c) }
    $secure.MakeReadOnly()
    $chars.Clear()
    $secure
}

function ConvertFrom-JmlSecureString {
    <#
    .SYNOPSIS
        Converts a SecureString to plain text for the single moment a Graph request body needs it.
    .DESCRIPTION
        Callers must overwrite the returned variable immediately after use and must never log it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Security.SecureString]$SecureString)

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
