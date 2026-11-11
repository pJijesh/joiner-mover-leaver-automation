# Least-privilege delegated scopes per operation. See docs/permissions.md for the Microsoft Learn
# reference behind each entry and the Entra roles the signed-in administrator also needs.
$script:JmlRequiredScopes = @{
    Joiner = @('User.ReadWrite.All', 'GroupMember.ReadWrite.All', 'Group.Read.All')
    Mover  = @('User.ReadWrite.All', 'GroupMember.ReadWrite.All', 'Group.Read.All')
    Leaver = @(
        'User.Read.All',
        'User.EnableDisableAccount.All',
        'User.RevokeSessions.All',
        'GroupMember.ReadWrite.All',
        'Group.Read.All',
        'UserAuthenticationMethod.ReadWrite.All',
        'LicenseAssignment.ReadWrite.All'
    )
}

# A broader permission that Microsoft documents as covering a narrower one.
$script:JmlScopeCovers = @{
    'User.Read.All'                   = @('User.ReadWrite.All', 'Directory.Read.All', 'Directory.ReadWrite.All')
    'User.ReadWrite.All'              = @('Directory.ReadWrite.All')
    'User.EnableDisableAccount.All'   = @('User.ReadWrite.All')
    'User.RevokeSessions.All'         = @('User.ReadWrite.All', 'Directory.ReadWrite.All')
    'LicenseAssignment.ReadWrite.All' = @('User.ReadWrite.All', 'Directory.ReadWrite.All')
    'GroupMember.ReadWrite.All'       = @('Group.ReadWrite.All', 'Directory.ReadWrite.All')
    'Group.Read.All'                  = @('Group.ReadWrite.All', 'Directory.Read.All', 'Directory.ReadWrite.All')
}

function Get-JmlRequiredScope {
    <#
    .SYNOPSIS
        Returns the delegated Graph scopes for one operation, or the union for All.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][ValidateSet('Joiner', 'Mover', 'Leaver', 'All')][string]$Operation)

    if ($Operation -eq 'All') { return @($script:JmlRequiredScopes.Values | ForEach-Object { $_ } | Select-Object -Unique | Sort-Object) }
    $script:JmlRequiredScopes[$Operation]
}

function Assert-JmlGraphContext {
    <#
    .SYNOPSIS
        Stops early, with a clear message, when there is no Graph connection or a scope is missing.
    .DESCRIPTION
        For delegated sign-ins the granted scopes are compared with the operation's requirements.
        For app-only sign-ins Graph reports roles rather than scopes, so a missing role is reported
        as a warning and the first Graph call is left to confirm.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Joiner', 'Mover', 'Leaver')][string]$Operation)

    $context = Get-MgContext -ErrorAction SilentlyContinue
    if (-not $context) { throw 'Not connected to Microsoft Graph. Run Connect-JmlGraph first.' }

    $granted = @(Get-JmlProperty $context 'Scopes' @())
    $missing = foreach ($scope in (Get-JmlRequiredScope -Operation $Operation)) {
        $covered = $scope -in $granted
        if (-not $covered -and $script:JmlScopeCovers.ContainsKey($scope)) {
            $covered = @($script:JmlScopeCovers[$scope] | Where-Object { $_ -in $granted }).Count -gt 0
        }
        if (-not $covered) { $scope }
    }
    if (@($missing).Count -eq 0) { return }

    $message = "Microsoft Graph connection is missing permissions for $($Operation): $(@($missing) -join ', '). Run Connect-JmlGraph -Operation $Operation."
    if ([string](Get-JmlProperty $context 'AuthType' '') -eq 'AppOnly') { Write-Warning $message }
    else { throw $message }
}
