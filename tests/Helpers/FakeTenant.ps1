# A small in-memory Entra ID tenant so tests can assert on outcomes (who is in which group,
# which calls were made) rather than only on call counts. Synthetic data only.

function New-FakeTenant {
    $tenant = [pscustomobject]@{
        Users    = [ordered]@{}
        Groups   = [ordered]@{}
        Members  = @{}
        Roles    = @{}
        Methods  = @{}
        Managers = @{}
        Reports  = @{}
        Calls    = [System.Collections.Generic.List[string]]::new()
        LastPassword = $null
        LastBody = $null
        Counter  = 0
        Context  = [pscustomobject]@{
            Account  = 'it.admin@northwind.example'
            AuthType = 'Delegated'
            Scopes   = @('User.ReadWrite.All', 'User.Read.All', 'User.EnableDisableAccount.All', 'User.RevokeSessions.All',
                'GroupMember.ReadWrite.All', 'Group.Read.All', 'UserAuthenticationMethod.ReadWrite.All', 'LicenseAssignment.ReadWrite.All')
        }
    }
    $global:JmlTenant = $tenant
    $tenant
}

function New-FakeId { param($Tenant) $Tenant.Counter++; ('00000000-0000-0000-0000-{0:D12}' -f $Tenant.Counter) }

function Add-FakeUser {
    param($Tenant, [string]$Upn, [string]$Name = '', [string]$EmployeeId = '', [string]$Department = '', [string]$JobTitle = '',
        [bool]$Enabled = $true, [string]$Manager = '', [bool]$Synced = $false, [string[]]$DirectSkus = @(), [string[]]$GroupSkus = @())
    $id = New-FakeId $Tenant
    $display = if ($Name) { $Name } else { $Upn.Split('@')[0] }
    $states = @()
    foreach ($sku in $DirectSkus) { $states += [pscustomobject]@{ SkuId = $sku; AssignedByGroup = $null; State = 'Active' } }
    foreach ($sku in $GroupSkus) { $states += [pscustomobject]@{ SkuId = $sku; AssignedByGroup = '11111111-1111-1111-1111-111111111111'; State = 'Active' } }
    $user = [pscustomobject]@{
        Id = $id; UserPrincipalName = $Upn; DisplayName = $display; GivenName = ''; Surname = ''
        Department = $Department; JobTitle = $JobTitle; OfficeLocation = ''; UsageLocation = 'GB'
        EmployeeId = $EmployeeId; AccountEnabled = $Enabled; OnPremisesSyncEnabled = $(if ($Synced) { $true } else { $null })
        LicenseAssignmentStates = $states
    }
    $Tenant.Users[$id] = $user
    if ($Manager) { $Tenant.Managers[$id] = ($Tenant.Users.Values | Where-Object UserPrincipalName -eq $Manager).Id }
    $user
}

function Add-FakeGroup {
    param($Tenant, [string]$Name, [switch]$Dynamic, [switch]$RoleAssignable, [switch]$MailEnabled, [switch]$Synced)
    $id = New-FakeId $Tenant
    $group = [pscustomobject]@{
        Id = $id; DisplayName = $Name
        GroupTypes = $(if ($Dynamic) { @('DynamicMembership', 'Unified') } else { @() })
        MembershipRule = $(if ($Dynamic) { 'user.department -eq "x"' } else { $null })
        IsAssignableToRole = [bool]$RoleAssignable; MailEnabled = [bool]$MailEnabled; SecurityEnabled = $true
        OnPremisesSyncEnabled = $(if ($Synced) { $true } else { $null })
    }
    $Tenant.Groups[$id] = $group
    $Tenant.Members[$id] = [System.Collections.Generic.List[string]]::new()
    $group
}

function Add-FakeMember {
    param($Tenant, [string]$GroupName, $User)
    $group = $Tenant.Groups.Values | Where-Object DisplayName -eq $GroupName
    if (-not $group) { throw "Fake group missing: $GroupName" }
    $Tenant.Members[$group.Id].Add($User.Id)
}

function Get-FakeGroupNames {
    param($Tenant, [string]$Upn)
    $user = $Tenant.Users.Values | Where-Object UserPrincipalName -eq $Upn
    if (-not $user) { return @() }
    @($Tenant.Groups.Values | Where-Object { $Tenant.Members[$_.Id].Contains($user.Id) } | ForEach-Object DisplayName | Sort-Object)
}

function Add-FakeMethod {
    param($Tenant, $User, [string]$Type, [string]$Id = '')
    if (-not $Id) { $Id = New-FakeId $Tenant }
    if (-not $Tenant.Methods.ContainsKey($User.Id)) { $Tenant.Methods[$User.Id] = [System.Collections.Generic.List[object]]::new() }
    $Tenant.Methods[$User.Id].Add([pscustomobject]@{ Id = $Id; AdditionalProperties = @{ '@odata.type' = "#microsoft.graph.$Type" } })
}

function Initialize-StandardTenant {
    # Groups from the sample configuration, plus a manager.
    param($Tenant)
    foreach ($name in 'NW-All-Staff', 'NW-Intranet-Readers', 'NW-Dept-Finance', 'NW-App-Accounting', 'NW-Role-Finance-Approvers',
        'NW-Role-Finance-Reporting', 'NW-Dept-Sales', 'NW-App-CRM', 'NW-Role-Sales-Forecast-Viewers', 'NW-Dept-Operations', 'NW-App-Dispatch',
        'NW-Dept-People', 'NW-App-HR-Records', 'NW-Dept-IT', 'NW-App-ServiceDesk', 'NW-Role-IT-Engineers', 'NW-Dept-Warehouse', 'NW-App-Stock',
        'NW-Role-Ops-Supervisors', 'NW-Role-Ops-Coordinators', 'NW-Role-Warehouse-Leads',
        'NW-Lic-Standard', 'NW-Lic-Frontline', 'NW-Lic-Premium', 'NW-BreakGlass-Exclusion', 'NW-Privileged-Admins') {
        $null = Add-FakeGroup -Tenant $Tenant -Name $name
    }
    $null = Add-FakeUser -Tenant $Tenant -Upn 'sam.rivera@northwind.example' -Name 'Sam Rivera' -EmployeeId 'NW0001' -Department 'Finance' -JobTitle 'Finance Manager'
}

function Register-FakeGraph {
    # Registers Pester mocks for every Graph cmdlet, backed by the fake tenant in $global:JmlTenant.
    Mock -ModuleName JmlAutomation Get-MgContext { $global:JmlTenant.Context }
    Mock -ModuleName JmlAutomation Start-Sleep { }

    Mock -ModuleName JmlAutomation Get-MgUser {
        $t = $global:JmlTenant
        $result = @()
        if ($Filter -match "^(\w+) eq '((?:[^']|'')*)'$") {
            $field = $Matches[1]; $value = $Matches[2].Replace("''", "'")
            $result = @($t.Users.Values | Where-Object { [string]$_.$field -ieq $value })
        }
        elseif ($UserId) { $result = @($t.Users.Values | Where-Object { $_.Id -eq $UserId -or $_.UserPrincipalName -ieq $UserId }) }
        $result | ForEach-Object { $_ | Select-Object * }
    }
    Mock -ModuleName JmlAutomation New-MgUser {
        $t = $global:JmlTenant
        $body = $BodyParameter
        $t.LastBody = $body
        $t.LastPassword = $body.passwordProfile.password
        $id = New-FakeId $t
        $user = [pscustomobject]@{
            Id = $id; UserPrincipalName = $body.userPrincipalName; DisplayName = $body.displayName; GivenName = $body.givenName
            Surname = $body.surname; Department = $body.department; JobTitle = $body.jobTitle
            OfficeLocation = $(if ($body.ContainsKey('officeLocation')) { $body.officeLocation } else { '' })
            UsageLocation = $body.usageLocation; EmployeeId = $body.employeeId; AccountEnabled = $body.accountEnabled
            OnPremisesSyncEnabled = $null; LicenseAssignmentStates = @()
        }
        $t.Users[$id] = $user
        $t.Calls.Add("New-MgUser:$($body.userPrincipalName)")
        $user
    }
    Mock -ModuleName JmlAutomation Update-MgUser {
        $t = $global:JmlTenant
        $user = $t.Users[$UserId]
        $changed = @()
        foreach ($name in 'Department', 'JobTitle', 'OfficeLocation', 'UsageLocation') {
            if ($PesterBoundParameters.ContainsKey($name)) { $user.$name = $PesterBoundParameters[$name]; $changed += $name }
        }
        if ($PesterBoundParameters.ContainsKey('AccountEnabled')) { $user.AccountEnabled = [bool]$AccountEnabled; $changed += "AccountEnabled=$([bool]$AccountEnabled)" }
        $t.Calls.Add("Update-MgUser:$($user.UserPrincipalName):$($changed -join ',')")
    }
    Mock -ModuleName JmlAutomation Get-MgUserManager {
        $t = $global:JmlTenant
        if (-not $t.Managers.ContainsKey($UserId)) { throw 'Request_ResourceNotFound: Resource does not exist.' }
        $m = $t.Users[$t.Managers[$UserId]]
        [pscustomobject]@{ Id = $m.Id; AdditionalProperties = @{ displayName = $m.DisplayName; userPrincipalName = $m.UserPrincipalName } }
    }
    Mock -ModuleName JmlAutomation Set-MgUserManagerByRef {
        $t = $global:JmlTenant
        $t.Managers[$UserId] = ($OdataId -split '/')[-1]
        $t.Calls.Add("Set-MgUserManagerByRef:$($t.Users[$UserId].UserPrincipalName)")
    }
    Mock -ModuleName JmlAutomation Get-MgUserMemberOf {
        $t = $global:JmlTenant
        foreach ($g in $t.Groups.Values) {
            if ($t.Members[$g.Id].Contains($UserId)) {
                [pscustomobject]@{ Id = $g.Id; AdditionalProperties = @{ '@odata.type' = '#microsoft.graph.group'; displayName = $g.DisplayName } }
            }
        }
        if ($t.Roles.ContainsKey($UserId)) {
            foreach ($r in $t.Roles[$UserId]) { [pscustomobject]@{ Id = "role-$r"; AdditionalProperties = @{ '@odata.type' = '#microsoft.graph.directoryRole'; displayName = $r } } }
        }
    }
    Mock -ModuleName JmlAutomation Get-MgUserDirectReport {
        $t = $global:JmlTenant
        foreach ($id in $t.Managers.Keys) {
            if ($t.Managers[$id] -eq $UserId) {
                $u = $t.Users[$id]
                [pscustomobject]@{ Id = $u.Id; AdditionalProperties = @{ displayName = $u.DisplayName; userPrincipalName = $u.UserPrincipalName } }
            }
        }
    }
    Mock -ModuleName JmlAutomation Get-MgGroup {
        $t = $global:JmlTenant
        if ($GroupId) { $t.Groups[$GroupId] | Select-Object *; return }
        if ($Filter -match "^displayName eq '((?:[^']|'')*)'$") {
            $name = $Matches[1].Replace("''", "'")
            $t.Groups.Values | Where-Object { $_.DisplayName -ieq $name } | ForEach-Object { $_ | Select-Object * }
        }
    }
    Mock -ModuleName JmlAutomation New-MgGroupMember {
        $t = $global:JmlTenant
        if ($t.Members[$GroupId].Contains($DirectoryObjectId)) { throw 'One or more added object references already exist for the following modified properties: members.' }
        $t.Members[$GroupId].Add($DirectoryObjectId)
        $t.Calls.Add("New-MgGroupMember:$($t.Groups[$GroupId].DisplayName):$($t.Users[$DirectoryObjectId].UserPrincipalName)")
    }
    Mock -ModuleName JmlAutomation Remove-MgGroupMemberByRef {
        $t = $global:JmlTenant
        $null = $t.Members[$GroupId].Remove($DirectoryObjectId)
        $t.Calls.Add("Remove-MgGroupMemberByRef:$($t.Groups[$GroupId].DisplayName):$($t.Users[$DirectoryObjectId].UserPrincipalName)")
    }
    Mock -ModuleName JmlAutomation Revoke-MgUserSignInSession {
        $global:JmlTenant.Calls.Add("Revoke-MgUserSignInSession:$($global:JmlTenant.Users[$UserId].UserPrincipalName)")
        $true
    }
    Mock -ModuleName JmlAutomation Get-MgUserAuthenticationMethod {
        $t = $global:JmlTenant
        if ($t.Methods.ContainsKey($UserId)) { $t.Methods[$UserId].ToArray() }
        [pscustomobject]@{ Id = 'password-method'; AdditionalProperties = @{ '@odata.type' = '#microsoft.graph.passwordAuthenticationMethod' } }
    }
    $removers = @{
        'Remove-MgUserAuthenticationPhoneMethod' = 'PhoneAuthenticationMethodId'
        'Remove-MgUserAuthenticationMicrosoftAuthenticatorMethod' = 'MicrosoftAuthenticatorAuthenticationMethodId'
        'Remove-MgUserAuthenticationFido2Method' = 'Fido2AuthenticationMethodId'
        'Remove-MgUserAuthenticationWindowsHelloForBusinessMethod' = 'WindowsHelloForBusinessAuthenticationMethodId'
        'Remove-MgUserAuthenticationSoftwareOathMethod' = 'SoftwareOathAuthenticationMethodId'
        'Remove-MgUserAuthenticationTemporaryAccessPassMethod' = 'TemporaryAccessPassAuthenticationMethodId'
        'Remove-MgUserAuthenticationEmailMethod' = 'EmailAuthenticationMethodId'
    }
    foreach ($name in $removers.Keys) {
        Mock -ModuleName JmlAutomation $name {
            $t = $global:JmlTenant
            $methodId = ($PesterBoundParameters.GetEnumerator() | Where-Object { $_.Key -like '*MethodId' } | Select-Object -First 1).Value
            $list = $t.Methods[$UserId]
            $found = $list | Where-Object Id -eq $methodId
            if ($found -and $found.AdditionalProperties.ContainsKey('default') -and $found.AdditionalProperties['default']) {
                throw 'Cannot delete the default authentication method.'
            }
            $null = $list.Remove($found)
            $t.Calls.Add("Remove-MethodType:$($found.AdditionalProperties['@odata.type'])")
        }
    }
    Mock -ModuleName JmlAutomation Set-MgUserLicense {
        $t = $global:JmlTenant
        $user = $t.Users[$UserId]
        $user.LicenseAssignmentStates = @($user.LicenseAssignmentStates | Where-Object { $_.SkuId -notin $RemoveLicenses })
        $t.Calls.Add("Set-MgUserLicense:$($user.UserPrincipalName):remove=$($RemoveLicenses.Count)")
    }
}
