# Signature-only stand-ins for the Microsoft Graph PowerShell SDK cmdlets this module calls.
# They let the Pester tests run on any machine, including CI, without installing the SDK or
# signing in. Every parameter name used here is checked against the real SDK by
# GraphContract.Tests.ps1 whenever the SDK is installed.
# Defined in the global scope so Pester can mock them inside the JmlAutomation module.

function global:Get-MgContext { [CmdletBinding()] param() }
function global:Connect-MgGraph { [CmdletBinding()] param($Scopes, $TenantId, $ClientId, $CertificateThumbprint, [switch]$NoWelcome, $ContextScope, [switch]$UseDeviceCode) }
function global:Get-MgUser { [CmdletBinding()] param($UserId, $Filter, [string[]]$Property, $ConsistencyLevel, $CountVariable, [switch]$All) }
function global:New-MgUser { [CmdletBinding()] param($BodyParameter) }
function global:Update-MgUser { [CmdletBinding()] param($UserId, [switch]$AccountEnabled, $Department, $JobTitle, $OfficeLocation, $UsageLocation) }
function global:Get-MgUserManager { [CmdletBinding()] param($UserId) }
function global:Set-MgUserManagerByRef { [CmdletBinding()] param($UserId, $OdataId) }
function global:Get-MgUserMemberOf { [CmdletBinding()] param($UserId, [switch]$All) }
function global:Get-MgUserDirectReport { [CmdletBinding()] param($UserId, [switch]$All) }
function global:Get-MgGroup { [CmdletBinding()] param($GroupId, $Filter, [string[]]$Property) }
function global:New-MgGroupMember { [CmdletBinding()] param($GroupId, $DirectoryObjectId) }
function global:Remove-MgGroupMemberByRef { [CmdletBinding()] param($GroupId, $DirectoryObjectId) }
function global:Revoke-MgUserSignInSession { [CmdletBinding()] param($UserId) }
function global:Get-MgUserAuthenticationMethod { [CmdletBinding()] param($UserId, [switch]$All) }
function global:Remove-MgUserAuthenticationPhoneMethod { [CmdletBinding()] param($UserId, $PhoneAuthenticationMethodId) }
function global:Remove-MgUserAuthenticationMicrosoftAuthenticatorMethod { [CmdletBinding()] param($UserId, $MicrosoftAuthenticatorAuthenticationMethodId) }
function global:Remove-MgUserAuthenticationFido2Method { [CmdletBinding()] param($UserId, $Fido2AuthenticationMethodId) }
function global:Remove-MgUserAuthenticationWindowsHelloForBusinessMethod { [CmdletBinding()] param($UserId, $WindowsHelloForBusinessAuthenticationMethodId) }
function global:Remove-MgUserAuthenticationSoftwareOathMethod { [CmdletBinding()] param($UserId, $SoftwareOathAuthenticationMethodId) }
function global:Remove-MgUserAuthenticationTemporaryAccessPassMethod { [CmdletBinding()] param($UserId, $TemporaryAccessPassAuthenticationMethodId) }
function global:Remove-MgUserAuthenticationEmailMethod { [CmdletBinding()] param($UserId, $EmailAuthenticationMethodId) }
function global:Set-MgUserLicense { [CmdletBinding()] param($UserId, $AddLicenses, [string[]]$RemoveLicenses) }
