# Thin wrappers around Microsoft Graph PowerShell SDK calls. Keeping them in one place
# means the property lists, filters and error handling are consistent and easy to review.

$script:JmlUserProperties = @(
    'id', 'userPrincipalName', 'displayName', 'givenName', 'surname', 'department', 'jobTitle',
    'officeLocation', 'usageLocation', 'employeeId', 'accountEnabled', 'onPremisesSyncEnabled'
)
$script:JmlGroupProperties = @(
    'id', 'displayName', 'groupTypes', 'membershipRule', 'isAssignableToRole',
    'mailEnabled', 'securityEnabled', 'onPremisesSyncEnabled'
)

function Protect-JmlODataString {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $Value.Replace("'", "''")
}

function Resolve-JmlUser {
    <#
    .SYNOPSIS
        Finds one user by user principal name or employee ID. Returns $null when none exists.
    #>
    [CmdletBinding()]
    param([string]$UserPrincipalName, [string]$EmployeeId)

    if ($UserPrincipalName) {
        $filter = "userPrincipalName eq '$(Protect-JmlODataString $UserPrincipalName)'"
        $found = @(Get-MgUser -Filter $filter -Property $script:JmlUserProperties -ErrorAction Stop)
    }
    elseif ($EmployeeId) {
        $filter = "employeeId eq '$(Protect-JmlODataString $EmployeeId)'"
        $found = @(Get-MgUser -Filter $filter -Property $script:JmlUserProperties -ConsistencyLevel eventual -CountVariable jmlCount -ErrorAction Stop)
    }
    else { throw 'Resolve-JmlUser needs a user principal name or an employee ID.' }

    if ($found.Count -gt 1) { throw "More than one user matched '$filter'. Resolve the duplicate before continuing." }
    if ($found.Count -eq 0) { return $null }
    $found[0]
}

function Get-JmlMembership {
    <#
    .SYNOPSIS
        Lists a user's direct memberships, classified as Group, DirectoryRole, AdministrativeUnit or Other.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserId)

    foreach ($item in @(Get-MgUserMemberOf -UserId $UserId -All -ErrorAction Stop)) {
        $type = [string](Get-JmlProperty $item '@odata.type' '')
        if (-not $type) { $type = [string](Get-JmlProperty $item 'OdataType' '') }
        $kind = switch -Regex ($type) {
            'microsoft\.graph\.group$' { 'Group' }
            'microsoft\.graph\.directoryRole$' { 'DirectoryRole' }
            'microsoft\.graph\.administrativeUnit$' { 'AdministrativeUnit' }
            default { 'Other' }
        }
        [pscustomobject]@{
            Id          = [string](Get-JmlProperty $item 'Id' '')
            Kind        = $kind
            DisplayName = [string](Get-JmlProperty $item 'displayName' '')
        }
    }
}

function Get-JmlGroupInfo {
    <#
    .SYNOPSIS
        Looks up a group by name or ID and works out whether the automation may change its membership.
    .OUTPUTS
        Object with Id, DisplayName, Manageable and Reason, or $null when the group does not exist.
    #>
    [CmdletBinding()]
    param([string]$Name, [string]$GroupId, [Parameter(Mandatory)]$Config)

    if ($Name) {
        $filter = "displayName eq '$(Protect-JmlODataString $Name)'"
        $found = @(Get-MgGroup -Filter $filter -Property $script:JmlGroupProperties -ErrorAction Stop)
        if ($found.Count -gt 1) { throw "More than one group is named '$Name'. Group names in the mapping must be unique." }
        if ($found.Count -eq 0) { return $null }
        $group = $found[0]
    }
    else {
        $group = Get-MgGroup -GroupId $GroupId -Property $script:JmlGroupProperties -ErrorAction Stop
        if (-not $group) { return $null }
    }

    $display = [string](Get-JmlProperty $group 'DisplayName' '')
    $types = @(Get-JmlProperty $group 'GroupTypes' @())
    $reason = $null
    if ($display -in @(Get-JmlProperty $Config.Protected 'protectedGroupNames' @())) { $reason = 'Protected group (protected-accounts.json)' }
    elseif ($types -contains 'DynamicMembership') { $reason = 'Dynamic membership: managed by rule, not by this tool' }
    elseif ((Get-JmlProperty $group 'IsAssignableToRole' $false) -eq $true) { $reason = 'Role-assignable group: needs Privileged Role Administrator, excluded by design' }
    elseif ((Get-JmlProperty $group 'OnPremisesSyncEnabled' $false) -eq $true) { $reason = 'Synced from on-premises Active Directory: change it there' }
    elseif ((Get-JmlProperty $group 'MailEnabled' $false) -eq $true -and $types -notcontains 'Unified') { $reason = 'Distribution list or mail-enabled security group: manage in Exchange' }

    [pscustomobject]@{
        Id          = [string](Get-JmlProperty $group 'Id' '')
        DisplayName = $display
        Manageable  = ($null -eq $reason)
        Dynamic     = ($types -contains 'DynamicMembership')
        Reason      = $reason
    }
}

function Test-JmlProtectedUser {
    <#
    .SYNOPSIS
        Returns a reason string when a user must not be touched by the automation, otherwise $null.
    .DESCRIPTION
        Checks, in order: the account running the automation, explicit protected accounts and
        patterns (break-glass), on-premises synced accounts, membership of protected groups,
        and holders of a directory (administrator) role.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$User,
        [object[]]$Membership = @()
    )

    $protected = $Config.Protected
    $upn = [string](Get-JmlProperty $User 'UserPrincipalName' '')
    $id = [string](Get-JmlProperty $User 'Id' '')

    $actor = ''
    try { $actor = [string](Get-JmlProperty (Get-MgContext -ErrorAction Stop) 'Account' '') } catch { Write-Verbose 'No Graph context for self-check.' }
    if ($actor -and $actor -ieq $upn) { return 'This is the account running the automation' }

    if ($upn -in @(Get-JmlProperty $protected 'userPrincipalNames' @())) { return 'Listed in protected-accounts.json (break-glass or privileged)' }
    foreach ($pattern in @(Get-JmlProperty $protected 'userPrincipalNamePatterns' @())) {
        if ($upn -like $pattern) { return "Matches protected pattern '$pattern'" }
    }
    if ($id -and $id -in @(Get-JmlProperty $protected 'objectIds' @())) { return 'Object ID listed in protected-accounts.json' }

    if ((Get-JmlProperty $protected 'refuseIfOnPremisesSynced' $true) -eq $true -and (Get-JmlProperty $User 'OnPremisesSyncEnabled' $false) -eq $true) {
        return 'Account is synced from on-premises Active Directory: change it at source'
    }
    if ((Get-JmlProperty $protected 'refuseIfMemberOfProtectedGroup' $true) -eq $true) {
        $names = @(Get-JmlProperty $protected 'protectedGroupNames' @())
        $hit = @($Membership | Where-Object { $_.Kind -eq 'Group' -and $_.DisplayName -in $names }) | Select-Object -First 1
        if ($hit) { return "Member of protected group '$($hit.DisplayName)'" }
    }
    if ((Get-JmlProperty $protected 'refuseIfDirectoryRoleHolder' $true) -eq $true) {
        if (@($Membership | Where-Object Kind -eq 'DirectoryRole').Count -gt 0) { return 'Holds an Entra directory (administrator) role' }
    }
    $null
}

function Get-JmlAttributeChange {
    <#
    .SYNOPSIS
        Compares wanted attributes with the current user and returns only those that differ.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$User, [Parameter(Mandatory)][hashtable]$Wanted)

    $changes = @{}
    foreach ($key in $Wanted.Keys) {
        $wantedValue = [string]$Wanted[$key]
        if (-not $wantedValue) { continue }
        $current = [string](Get-JmlProperty $User $key '')
        if ($current -cne $wantedValue) { $changes[$key] = $wantedValue }
    }
    $changes
}

function Set-JmlManager {
    <#
    .SYNOPSIS
        Sets a user's manager (Graph reference update).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Always called from Invoke-JmlStep, which owns ShouldProcess.')]
    param([Parameter(Mandatory)][string]$UserId, [Parameter(Mandatory)][string]$ManagerId)

    Set-MgUserManagerByRef -UserId $UserId -OdataId "https://graph.microsoft.com/v1.0/users/$ManagerId" -ErrorAction Stop
}

function Get-JmlManagerId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$UserId)
    try { $manager = Get-MgUserManager -UserId $UserId -ErrorAction Stop }
    catch { Write-Verbose "No manager returned for $UserId."; return '' }
    [string](Get-JmlProperty $manager 'Id' '')
}

function Get-JmlMfaMethodMap {
    <#
    .SYNOPSIS
        Maps Graph authentication method types to the SDK cmdlet and parameter that deletes them.
    .DESCRIPTION
        The password method cannot be deleted and is intentionally absent.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{
        '#microsoft.graph.phoneAuthenticationMethod'                = @{ Label = 'phone'; Cmdlet = 'Remove-MgUserAuthenticationPhoneMethod'; Parameter = 'PhoneAuthenticationMethodId' }
        '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod' = @{ Label = 'authenticator'; Cmdlet = 'Remove-MgUserAuthenticationMicrosoftAuthenticatorMethod'; Parameter = 'MicrosoftAuthenticatorAuthenticationMethodId' }
        '#microsoft.graph.fido2AuthenticationMethod'                = @{ Label = 'fido2'; Cmdlet = 'Remove-MgUserAuthenticationFido2Method'; Parameter = 'Fido2AuthenticationMethodId' }
        '#microsoft.graph.windowsHelloForBusinessAuthenticationMethod' = @{ Label = 'windowsHello'; Cmdlet = 'Remove-MgUserAuthenticationWindowsHelloForBusinessMethod'; Parameter = 'WindowsHelloForBusinessAuthenticationMethodId' }
        '#microsoft.graph.softwareOathAuthenticationMethod'         = @{ Label = 'softwareOath'; Cmdlet = 'Remove-MgUserAuthenticationSoftwareOathMethod'; Parameter = 'SoftwareOathAuthenticationMethodId' }
        '#microsoft.graph.temporaryAccessPassAuthenticationMethod'  = @{ Label = 'temporaryAccessPass'; Cmdlet = 'Remove-MgUserAuthenticationTemporaryAccessPassMethod'; Parameter = 'TemporaryAccessPassAuthenticationMethodId' }
        '#microsoft.graph.emailAuthenticationMethod'                = @{ Label = 'email'; Cmdlet = 'Remove-MgUserAuthenticationEmailMethod'; Parameter = 'EmailAuthenticationMethodId' }
    }
}
