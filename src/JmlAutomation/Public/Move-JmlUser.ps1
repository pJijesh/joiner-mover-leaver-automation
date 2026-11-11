function Move-JmlUser {
    <#
    .SYNOPSIS
        Applies a department, job title, location or manager change to an existing account.
    .DESCRIPTION
        Works out the groups the person should hold for the new department and job title, removes
        groups from the old role that are no longer wanted, adds the new ones, and updates the
        attributes that changed. Baseline groups are always preserved. Only groups named in
        config/department-groups.json (and the licence groups in config/licences.json) are ever
        added or removed, so access granted manually elsewhere is left alone.

        Accounts listed in config/protected-accounts.json, administrator role holders, members of
        protected groups, on-premises synced accounts and disabled accounts are refused.
        The command is idempotent: running it twice makes no second change.
    .PARAMETER UserPrincipalName
        The person being moved.
    .PARAMETER Department
        New department. Leave out to keep the current department.
    .PARAMETER JobTitle
        New job title. Leave out to keep the current title.
    .PARAMETER ManagerUserPrincipalName
        New line manager (optional).
    .PARAMETER OfficeLocation
        New office (optional).
    .PARAMETER ApprovalReference
        Ticket or HR reference authorising the change. Stored in the audit log.
    .EXAMPLE
        Move-JmlUser -UserPrincipalName alex.morgan@northwind.example -Department Sales `
            -JobTitle 'Sales Manager' -ApprovalReference HR-2044 -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$UserPrincipalName,
        [string]$Department,
        [string]$JobTitle,
        [Alias('ManagerUpn')][string]$ManagerUserPrincipalName,
        [string]$OfficeLocation,
        [string]$ApprovalReference = '',
        [string]$ConfigPath,
        [string]$AuditLogPath,
        [string]$RunId
    )

    $config = Import-JmlConfig -Path $ConfigPath
    Assert-JmlGraphContext -Operation Mover
    $dryRun = [bool]$WhatIfPreference
    $context = New-JmlContext -Operation 'Mover' -Target $UserPrincipalName -Cmdlet $PSCmdlet `
        -AuditLogPath (Resolve-JmlAuditPath -Config $config -AuditLogPath $AuditLogPath) `
        -DryRun $dryRun -ApprovalReference $ApprovalReference -RunId $RunId
    $null = Add-JmlRecord -Context $context -Action 'Start' -Result $(if ($dryRun) { 'WhatIf' } else { 'Succeeded' })

    if (-not ($Department -or $JobTitle -or $ManagerUserPrincipalName -or $OfficeLocation)) {
        $null = Add-JmlRecord -Context $context -Action 'Validate' -Result 'Failed' -ErrorMessage 'Supply at least one of Department, JobTitle, ManagerUserPrincipalName or OfficeLocation.'
        return New-JmlResult -Context $context -Status 'Failed'
    }

    $user = Resolve-JmlUser -UserPrincipalName $UserPrincipalName
    if (-not $user) {
        $null = Add-JmlRecord -Context $context -Action 'ResolveUser' -Result 'Failed' -ErrorMessage 'User not found.'
        return New-JmlResult -Context $context -Status 'Failed'
    }
    $userId = [string](Get-JmlProperty $user 'Id' '')
    $membership = @(Get-JmlMembership -UserId $userId)

    # Guards.
    $refusal = Test-JmlProtectedUser -Config $config -User $user -Membership $membership
    if (-not $refusal -and (Get-JmlProperty $user 'AccountEnabled' $true) -eq $false) { $refusal = 'Account is disabled; a leaver cannot be moved.' }
    if ($refusal) {
        $null = Add-JmlRecord -Context $context -Action 'ProtectionCheck' -Result 'Refused' -ErrorMessage $refusal
        return New-JmlResult -Context $context -Status 'Refused'
    }

    $newDepartment = if ($Department) { $Department } else { [string](Get-JmlProperty $user 'Department' '') }
    $newJobTitle = if ($JobTitle) { $JobTitle } else { [string](Get-JmlProperty $user 'JobTitle' '') }
    try { $desired = Get-JmlDesiredGroup -Config $config -Department $newDepartment -JobTitle $newJobTitle }
    catch {
        $null = Add-JmlRecord -Context $context -Action 'Validate' -Result 'Failed' -ErrorMessage (Format-JmlError -ErrorRecord $_)
        return New-JmlResult -Context $context -Status 'Failed'
    }

    $manager = $null
    if ($ManagerUserPrincipalName) {
        $manager = Resolve-JmlUser -UserPrincipalName $ManagerUserPrincipalName
        if (-not $manager -or (Get-JmlProperty $manager 'AccountEnabled' $true) -eq $false) {
            $null = Add-JmlRecord -Context $context -Action 'ResolveManager' -Result 'Failed' -ErrorMessage 'New manager not found or disabled.' -Detail @{ manager = $ManagerUserPrincipalName }
            return New-JmlResult -Context $context -Status 'Failed'
        }
    }

    # Attributes.
    $changes = Get-JmlAttributeChange -User $user -Wanted @{ Department = $Department; JobTitle = $JobTitle; OfficeLocation = $OfficeLocation }
    if ($changes.Count -gt 0) {
        $null = Invoke-JmlStep -Context $context -Action 'UpdateAttributes' -Detail @{ attributes = @($changes.Keys | Sort-Object) } -Script {
            Update-MgUser -UserId $userId @changes -ErrorAction Stop
        }
    }
    else { $null = Add-JmlRecord -Context $context -Action 'UpdateAttributes' -Result 'NoChange' }

    # Manager.
    if ($manager) {
        $newManagerId = [string](Get-JmlProperty $manager 'Id' '')
        if ((Get-JmlManagerId -UserId $userId) -ieq $newManagerId) {
            $null = Add-JmlRecord -Context $context -Action 'SetManager' -Result 'NoChange'
        }
        else {
            $null = Invoke-JmlStep -Context $context -Action 'SetManager' -Detail @{ manager = $ManagerUserPrincipalName } -Script {
                Set-JmlManager -UserId $userId -ManagerId $newManagerId
            }
        }
    }

    # Groups: remove managed groups that are no longer wanted, add the missing ones.
    $managedNames = Get-JmlManagedGroupName -Config $config
    $currentGroups = @($membership | Where-Object Kind -eq 'Group')
    $currentIds = @($currentGroups | ForEach-Object { $_.Id })

    # Additions run first so a licence group swap never leaves a gap in licensing.
    foreach ($groupName in $desired.All) {
        $isLicence = ($groupName -eq $desired.LicenceGroup)
        $actionName = if ($isLicence) { 'AssignLicenceGroup' } else { 'AddToGroup' }
        try { $group = Get-JmlGroupInfo -Name $groupName -Config $config }
        catch { $null = Add-JmlRecord -Context $context -Action $actionName -Result 'Failed' -Target $groupName -ErrorMessage (Format-JmlError -ErrorRecord $_); continue }
        if (-not $group) {
            $null = Add-JmlRecord -Context $context -Action $actionName -Result 'Failed' -Target $groupName -ErrorMessage 'Group not found in Entra ID.'
            continue
        }
        if (-not $group.Manageable) {
            $null = Add-JmlRecord -Context $context -Action $actionName -Result 'Skipped' -Target $groupName -Detail @{ reason = $group.Reason }
            continue
        }
        if ($group.Id -in $currentIds) {
            $null = Add-JmlRecord -Context $context -Action $actionName -Result 'NoChange' -Target $groupName
            continue
        }
        $null = Invoke-JmlStep -Context $context -Action $actionName -Target $groupName -Script {
            try { New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $userId -ErrorAction Stop }
            catch { if ($_.Exception.Message -notmatch '(?i)already exist') { throw } }
        }
    }

    # Then remove managed groups from the old role that are no longer wanted.
    foreach ($held in $currentGroups) {
        if ($held.DisplayName -notin $managedNames -or $held.DisplayName -in $desired.All) { continue }
        try { $group = Get-JmlGroupInfo -GroupId $held.Id -Config $config }
        catch { $null = Add-JmlRecord -Context $context -Action 'RemoveFromGroup' -Result 'Failed' -Target $held.DisplayName -ErrorMessage (Format-JmlError -ErrorRecord $_); continue }
        if (-not $group -or -not $group.Manageable) {
            $reason = if ($group) { $group.Reason } else { 'Group no longer exists.' }
            $null = Add-JmlRecord -Context $context -Action 'RemoveFromGroup' -Result 'Skipped' -Target $held.DisplayName -Detail @{ reason = $reason }
            continue
        }
        $null = Invoke-JmlStep -Context $context -Action 'RemoveFromGroup' -Target $held.DisplayName -Script {
            try { Remove-MgGroupMemberByRef -GroupId $group.Id -DirectoryObjectId $userId -ErrorAction Stop }
            catch { if ($_.Exception.Message -notmatch '(?i)does not exist|ResourceNotFound|not a member') { throw } }
        }
    }

    New-JmlResult -Context $context -UserPrincipalName $UserPrincipalName
}
