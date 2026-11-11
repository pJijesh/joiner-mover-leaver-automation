function Remove-JmlLeaver {
    <#
    .SYNOPSIS
        Offboards a leaver: blocks sign-in, revokes sessions, removes access and produces a checklist.
    .DESCRIPTION
        Automated steps, in order:
          1. Snapshot manager, direct reports, group memberships and authentication methods.
          2. Disable sign-in.
          3. Revoke refresh tokens and sign-in sessions (repeated on every run, which is safe).
          4. Remove registered authentication methods where Entra ID permits (optional).
          5. Remove the person from groups the automation may change.
          6. Reclaim licences (direct assignments and licence groups), once the mailbox has been
             converted. By default licences are held back until -MailboxConverted is supplied,
             because an unlicensed user mailbox cannot be converted to a shared mailbox.
          7. Write a Markdown checklist covering the steps Graph cannot do: shared mailbox conversion,
             OneDrive access and retention, devices, third-party applications and manager handover.

        The account is never deleted. Break-glass accounts, administrators, members of protected groups,
        on-premises synced accounts and the account running the automation are refused.
        The command is idempotent and supports -WhatIf.
    .PARAMETER UserPrincipalName
        The leaver.
    .PARAMETER LeaveDate
        Contractual last day, shown in the checklist.
    .PARAMETER MailboxConverted
        Confirms the mailbox has been converted to a shared mailbox, releasing the licence hold.
    .PARAMETER SkipMfaReset
        Keep registered authentication methods (for example when forensics needs them).
    .PARAMETER OutputPath
        Folder for the checklist. Defaults to the output folder from settings.json.
    .PARAMETER ApprovalReference
        Ticket or HR reference authorising the change. Stored in the audit log.
    .EXAMPLE
        Remove-JmlLeaver -UserPrincipalName jamie.okafor@northwind.example -LeaveDate 2026-12-18 -ApprovalReference HR-3101 -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$UserPrincipalName,
        [Nullable[datetime]]$LeaveDate,
        [switch]$MailboxConverted,
        [switch]$SkipMfaReset,
        [string]$OutputPath,
        [string]$ApprovalReference = '',
        [string]$ConfigPath,
        [string]$AuditLogPath,
        [string]$RunId
    )

    $config = Import-JmlConfig -Path $ConfigPath
    Assert-JmlGraphContext -Operation Leaver
    $dryRun = [bool]$WhatIfPreference
    $context = New-JmlContext -Operation 'Leaver' -Target $UserPrincipalName -Cmdlet $PSCmdlet `
        -AuditLogPath (Resolve-JmlAuditPath -Config $config -AuditLogPath $AuditLogPath) `
        -DryRun $dryRun -ApprovalReference $ApprovalReference -RunId $RunId
    $null = Add-JmlRecord -Context $context -Action 'Start' -Result $(if ($dryRun) { 'WhatIf' } else { 'Succeeded' })

    $user = Resolve-JmlUser -UserPrincipalName $UserPrincipalName
    if (-not $user) {
        $null = Add-JmlRecord -Context $context -Action 'ResolveUser' -Result 'Failed' -ErrorMessage 'User not found.'
        return New-JmlResult -Context $context -Status 'Failed'
    }
    $userId = [string](Get-JmlProperty $user 'Id' '')
    $displayName = [string](Get-JmlProperty $user 'DisplayName' $UserPrincipalName)

    # 1. Snapshot before anything changes.
    $membership = @(Get-JmlMembership -UserId $userId)
    $refusal = Test-JmlProtectedUser -Config $config -User $user -Membership $membership
    if ($refusal) {
        $null = Add-JmlRecord -Context $context -Action 'ProtectionCheck' -Result 'Refused' -ErrorMessage $refusal
        return New-JmlResult -Context $context -Status 'Refused'
    }

    $managerInfo = $null
    try { $managerInfo = Get-MgUserManager -UserId $userId -ErrorAction Stop } catch { Write-Verbose 'Leaver has no manager recorded.' }
    $managerText = if ($managerInfo) {
        $name = [string](Get-JmlProperty $managerInfo 'displayName' '')
        $mUpn = [string](Get-JmlProperty $managerInfo 'userPrincipalName' '')
        if ($name -or $mUpn) { "$name ($mUpn)".Trim() } else { [string](Get-JmlProperty $managerInfo 'Id' 'recorded') }
    } else { 'None recorded in Entra ID' }

    $directReports = @()
    try {
        $directReports = @(Get-MgUserDirectReport -UserId $userId -All -ErrorAction Stop | ForEach-Object {
                $n = [string](Get-JmlProperty $_ 'displayName' '')
                $u = [string](Get-JmlProperty $_ 'userPrincipalName' '')
                if ($n -or $u) { "$n ($u)".Trim() } else { [string](Get-JmlProperty $_ 'Id' '') }
            })
    }
    catch { $null = Add-JmlRecord -Context $context -Action 'ReadDirectReports' -Result 'Failed' -ErrorMessage (Format-JmlError -ErrorRecord $_) }

    $methods = @()
    $methodsRead = $false
    try { $methods = @(Get-MgUserAuthenticationMethod -UserId $userId -All -ErrorAction Stop); $methodsRead = $true }
    catch { $null = Add-JmlRecord -Context $context -Action 'ReadAuthenticationMethods' -Result 'Failed' -ErrorMessage (Format-JmlError -ErrorRecord $_) }

    $licenceGroupNames = @(Get-JmlProperty $config.Licences 'licenceGroups' @())
    $managedNames = Get-JmlManagedGroupName -Config $config
    $groupsBefore = @($membership | Where-Object Kind -eq 'Group' | ForEach-Object { $_.DisplayName } | Sort-Object)
    $skippedGroups = [System.Collections.Generic.List[string]]::new()

    # Licence gate: hold licences until the mailbox has been converted.
    $gateOn = ((Get-JmlSetting -Config $config -Name 'leaver.requireMailboxConversionBeforeLicenceRemoval') -eq $true) -and -not $MailboxConverted

    $null = Add-JmlRecord -Context $context -Action 'Snapshot' -Result 'NoChange' -Detail @{
        groupCount = $groupsBefore.Count; directReportCount = $directReports.Count
        authenticationMethodCount = $methods.Count; licenceHold = $gateOn
    }

    # 2. Disable sign-in.
    if ((Get-JmlProperty $user 'AccountEnabled' $true) -eq $false) {
        $null = Add-JmlRecord -Context $context -Action 'DisableAccount' -Result 'NoChange' -Detail @{ reason = 'Already disabled.' }
    }
    else {
        $null = Invoke-JmlStep -Context $context -Action 'DisableAccount' -Script { Update-MgUser -UserId $userId -AccountEnabled:$false -ErrorAction Stop }
    }

    # 3. Revoke sessions (harmless to repeat; covers accounts disabled by hand earlier).
    $null = Invoke-JmlStep -Context $context -Action 'RevokeSessions' -Script { Revoke-MgUserSignInSession -UserId $userId -ErrorAction Stop }

    # 4. Authentication methods.
    $mfaSummary = 'Could not be read.'
    if ($methodsRead) {
        $types = @($methods | ForEach-Object { ([string](Get-JmlProperty $_ '@odata.type' '') -replace '^#microsoft\.graph\.', '' -replace 'AuthenticationMethod$', '') } | Group-Object | ForEach-Object { "$($_.Name) x$($_.Count)" })
        $mfaSummary = if ($types.Count -gt 0) { $types -join ', ' } else { 'No registered methods.' }
    }
    $resetMfa = (Get-JmlSetting -Config $config -Name 'leaver.resetMfaMethods') -eq $true -and -not $SkipMfaReset
    $methodMap = Get-JmlMfaMethodMap
    if (-not $resetMfa) {
        $null = Add-JmlRecord -Context $context -Action 'ResetMfaMethods' -Result 'Skipped' -Detail @{ reason = 'Disabled by setting or -SkipMfaReset.' }
    }
    else {
        # Phone methods last: Entra refuses to delete a phone that is the default method.
        $ordered = @($methods | Sort-Object { if ((Get-JmlProperty $_ '@odata.type' '') -like '*phoneAuthenticationMethod') { 1 } else { 0 } })
        $handled = 0
        foreach ($method in $ordered) {
            $type = [string](Get-JmlProperty $method '@odata.type' '')
            $methodId = [string](Get-JmlProperty $method 'Id' '')
            if ($type -like '*passwordAuthenticationMethod') { continue }
            $entry = $methodMap[$type]
            if (-not $entry) {
                $null = Add-JmlRecord -Context $context -Action 'RemoveAuthenticationMethod' -Result 'Skipped' -Target $type -Detail @{ reason = 'Method type not handled by this tool; review manually.' }
                continue
            }
            $handled++
            $null = Invoke-JmlStep -Context $context -Action 'RemoveAuthenticationMethod' -Target "$($entry.Label):$methodId" `
                -Detail @{ methodType = $entry.Label } `
                -TolerateErrorPattern '(?i)default|cannot be deleted|can''t be deleted' -TolerateReason 'Entra ID will not delete a default method; remove it after changing the default.' -Script {
                $arguments = @{ UserId = $userId; ErrorAction = 'Stop' }
                $arguments[$entry.Parameter] = $methodId
                & $entry.Cmdlet @arguments
            }
        }
        if ($handled -eq 0) { $null = Add-JmlRecord -Context $context -Action 'RemoveAuthenticationMethod' -Result 'NoChange' -Detail @{ reason = 'No removable methods registered.' } }
    }

    # 5. Groups.
    $removalScope = [string](Get-JmlSetting -Config $config -Name 'leaver.groupRemoval')
    $removedAny = $false
    foreach ($held in @($membership | Where-Object Kind -eq 'Group')) {
        $isLicenceGroup = $held.DisplayName -in $licenceGroupNames
        if ($isLicenceGroup -and $gateOn) {
            $null = Add-JmlRecord -Context $context -Action 'RemoveFromGroup' -Result 'Skipped' -Target $held.DisplayName -Detail @{ reason = 'Licence group held until the mailbox is converted (use -MailboxConverted).' }
            continue
        }
        if ($removalScope -eq 'ManagedOnly' -and $held.DisplayName -notin $managedNames) {
            $null = Add-JmlRecord -Context $context -Action 'RemoveFromGroup' -Result 'Skipped' -Target $held.DisplayName -Detail @{ reason = 'Outside the managed group set (groupRemoval is ManagedOnly).' }
            $skippedGroups.Add("$($held.DisplayName): outside managed set")
            continue
        }
        try { $group = Get-JmlGroupInfo -GroupId $held.Id -Config $config }
        catch { $null = Add-JmlRecord -Context $context -Action 'RemoveFromGroup' -Result 'Failed' -Target $held.DisplayName -ErrorMessage (Format-JmlError -ErrorRecord $_); continue }
        if (-not $group -or -not $group.Manageable) {
            $reason = if ($group) { $group.Reason } else { 'Group no longer exists.' }
            $null = Add-JmlRecord -Context $context -Action 'RemoveFromGroup' -Result 'Skipped' -Target $held.DisplayName -Detail @{ reason = $reason }
            $skippedGroups.Add("$($held.DisplayName): $reason")
            continue
        }
        $removedAny = $true
        $null = Invoke-JmlStep -Context $context -Action 'RemoveFromGroup' -Target $held.DisplayName -Script {
            try { Remove-MgGroupMemberByRef -GroupId $group.Id -DirectoryObjectId $userId -ErrorAction Stop }
            catch { if ($_.Exception.Message -notmatch '(?i)does not exist|ResourceNotFound|not a member') { throw } }
        }
    }
    if (-not $removedAny -and $membership.Count -eq 0) { $null = Add-JmlRecord -Context $context -Action 'RemoveFromGroup' -Result 'NoChange' -Detail @{ reason = 'No group memberships.' } }

    # 6. Directly assigned licences. Licences from groups are reclaimed by the group removals above.
    $licencesHeld = $false
    if ($gateOn) {
        $licencesHeld = $true
        $null = Add-JmlRecord -Context $context -Action 'RemoveDirectLicences' -Result 'Skipped' -Detail @{ reason = 'Held until the mailbox is converted (use -MailboxConverted).' }
    }
    else {
        $directSkus = @()
        try {
            $licenceUser = Get-MgUser -UserId $userId -Property 'id', 'assignedLicenses', 'licenseAssignmentStates' -ErrorAction Stop
            $states = @(Get-JmlProperty $licenceUser 'LicenseAssignmentStates' @())
            $directSkus = @($states | Where-Object { -not (Get-JmlProperty $_ 'AssignedByGroup' $null) } | ForEach-Object { [string](Get-JmlProperty $_ 'SkuId' '') } | Where-Object { $_ } | Select-Object -Unique)
        }
        catch { $null = Add-JmlRecord -Context $context -Action 'ReadLicences' -Result 'Failed' -ErrorMessage (Format-JmlError -ErrorRecord $_) }
        if ($directSkus.Count -gt 0) {
            $null = Invoke-JmlStep -Context $context -Action 'RemoveDirectLicences' -Detail @{ skuCount = $directSkus.Count } -Script {
                Set-MgUserLicense -UserId $userId -AddLicenses @() -RemoveLicenses ([string[]]$directSkus) -ErrorAction Stop
            }
        }
        else { $null = Add-JmlRecord -Context $context -Action 'RemoveDirectLicences' -Result 'NoChange' -Detail @{ reason = 'No directly assigned licences.' } }
    }

    # 7. Checklist.
    $outputDirectory = if ($OutputPath) { $OutputPath } else {
        $configured = [string](Get-JmlSetting -Config $config -Name 'output.directory')
        if ([System.IO.Path]::IsPathRooted($configured)) { $configured } else { Join-Path (Get-Location).ProviderPath $configured }
    }
    $snapshot = @{
        UserPrincipalName = $UserPrincipalName
        DisplayName       = $displayName
        LeaveDate         = $LeaveDate
        LeaveDateText     = $(if ($LeaveDate) { $LeaveDate.ToString('yyyy-MM-dd') } else { 'Not supplied' })
        ManagerText       = $managerText
        DirectReports     = $directReports
        GroupsBefore      = $groupsBefore
        GroupsSkipped     = @($skippedGroups)
        MfaSummary        = $mfaSummary
        LicencesHeld      = $licencesHeld
    }
    $checklistPath = $null
    try {
        $checklistPath = Export-JmlLeaverChecklist -Context $context -OutputDirectory $outputDirectory -Snapshot $snapshot
        $null = Add-JmlRecord -Context $context -Action 'WriteChecklist' -Result 'Succeeded' -Detail @{ file = (Split-Path $checklistPath -Leaf) }
    }
    catch { $null = Add-JmlRecord -Context $context -Action 'WriteChecklist' -Result 'Failed' -ErrorMessage (Format-JmlError -ErrorRecord $_) }

    New-JmlResult -Context $context -UserPrincipalName $UserPrincipalName -Extra @{ ChecklistPath = $checklistPath; LicencesHeld = $licencesHeld }
}
