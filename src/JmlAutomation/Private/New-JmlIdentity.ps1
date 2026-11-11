function New-JmlIdentity {
    <#
    .SYNOPSIS
        Builds the user principal name, mail nickname and display name for a new joiner.
    .DESCRIPTION
        Applies the naming convention from config/naming.json. Sequence 1 is the plain name;
        sequence 2 and above append a number to the local part to resolve collisions.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object only.')]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$GivenName,
        [Parameter(Mandatory)][string]$Surname,
        [string]$EmployeeId = '',
        [ValidateRange(1, 1000)][int]$Sequence = 1
    )

    $naming = $Config.Naming
    $given = ConvertTo-JmlSlug -Name $GivenName
    $family = ConvertTo-JmlSlug -Name $Surname
    if (-not $given -or -not $family) {
        throw 'Given name and surname must contain at least one letter or digit after normalisation.'
    }

    $apply = {
        param([string]$Format)
        $text = $Format.Replace('{given}', $given).Replace('{surname}', $family)
        $text = $text.Replace('{givenInitial}', $given.Substring(0, 1))
        $text.Replace('{employeeId}', (ConvertTo-JmlSlug -Name $EmployeeId))
    }

    $maxLength = [int](Get-JmlProperty $naming 'maxLocalPartLength' 40)
    $suffix = if ($Sequence -gt 1) { [string]$Sequence } else { '' }

    $localPart = & $apply ([string]$naming.userPrincipalNameFormat)
    if ($localPart.Length + $suffix.Length -gt $maxLength) {
        $localPart = $localPart.Substring(0, $maxLength - $suffix.Length)
    }
    $localPart = $localPart.TrimEnd('.', '-') + $suffix

    $nickname = & $apply ([string]$naming.mailNicknameFormat)
    if ($nickname.Length + $suffix.Length -gt $maxLength) {
        $nickname = $nickname.Substring(0, $maxLength - $suffix.Length)
    }
    $nickname = $nickname.TrimEnd('.', '-') + $suffix

    $displayName = ([string]$naming.displayNameFormat).Replace('{given}', $GivenName.Trim()).Replace('{surname}', $Surname.Trim())
    $displayName = $displayName.Replace('{givenInitial}', $GivenName.Trim().Substring(0, 1)).Replace('{employeeId}', $EmployeeId)

    [pscustomobject]@{
        UserPrincipalName = "$localPart@$($naming.domain)"
        MailNickname      = $nickname
        DisplayName       = $displayName.Trim()
        Sequence          = $Sequence
    }
}
