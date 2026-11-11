function Connect-JmlGraph {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph with only the permissions needed for the chosen operation.
    .DESCRIPTION
        Interactive use requests delegated scopes for the selected operation. Unattended use takes a
        client ID, tenant ID and certificate thumbprint for an app registration whose application
        permissions you have granted separately (see docs/permissions.md). Tenant identifiers are
        supplied by you at run time and are never stored in this repository.
    .PARAMETER Operation
        Joiner, Mover, Leaver, or All (union of the three).
    .PARAMETER TenantId
        Optional tenant ID or domain. Required for app-only sign-in.
    .PARAMETER ClientId
        App registration (client) ID for certificate-based, unattended sign-in.
    .PARAMETER CertificateThumbprint
        Thumbprint of the certificate installed for the app registration.
    .PARAMETER UseDeviceCode
        Use device-code sign-in for delegated access on a machine without a browser.
    .EXAMPLE
        Connect-JmlGraph -Operation Joiner
    .EXAMPLE
        Connect-JmlGraph -Operation Leaver -TenantId 'northwind.example'
    .OUTPUTS
        The Graph context (account, tenant and granted scopes) after sign-in.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Delegated')]
    param(
        [Parameter(Mandatory)][ValidateSet('Joiner', 'Mover', 'Leaver', 'All')][string]$Operation,
        [Parameter(ParameterSetName = 'Delegated')]
        [Parameter(Mandatory, ParameterSetName = 'AppOnly')]
        [string]$TenantId,
        [Parameter(ParameterSetName = 'Delegated')][switch]$UseDeviceCode,
        [Parameter(Mandatory, ParameterSetName = 'AppOnly')][string]$ClientId,
        [Parameter(Mandatory, ParameterSetName = 'AppOnly')][string]$CertificateThumbprint
    )

    if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
        throw 'The Microsoft Graph PowerShell SDK is not installed. Run: Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Users.Actions, Microsoft.Graph.Groups, Microsoft.Graph.Identity.SignIns -Scope CurrentUser'
    }

    if ($PSCmdlet.ParameterSetName -eq 'AppOnly') {
        Connect-MgGraph -ClientId $ClientId -TenantId $TenantId -CertificateThumbprint $CertificateThumbprint -NoWelcome -ContextScope Process | Out-Null
    }
    else {
        $arguments = @{
            Scopes       = (Get-JmlRequiredScope -Operation $Operation)
            NoWelcome    = $true
            ContextScope = 'Process'
        }
        if ($TenantId) { $arguments.TenantId = $TenantId }
        if ($UseDeviceCode) { $arguments.UseDeviceCode = $true }
        Connect-MgGraph @arguments | Out-Null
    }
    Get-MgContext
}
