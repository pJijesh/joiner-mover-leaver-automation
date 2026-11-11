function New-JmlJoiner {
    <#
    .SYNOPSIS
        Creates (or completes) the Entra ID account for a new starter from an HR record.
    .DESCRIPTION
        Creates the user, sets manager, department, job title and usage location, adds the person to
        the baseline, department and role groups from config/department-groups.json, and adds them to
        the licence group from config/licences.json so group-based licensing assigns the licence.
        A random one-time password is generated with forced change at first sign-in. The password is
        returned only as a SecureString (or handed to -CredentialHandler) and is never written to the
        audit log.

        The command is idempotent: if an account with the same employee ID already exists it is
        reconciled (missing attributes, manager and groups are added) rather than recreated.
        Use -WhatIf to see every action without changing anything.
    .PARAMETER EmployeeId
        Unique HR identifier. Used to find an existing account and keep re-runs safe.
    .PARAMETER ManagerUserPrincipalName
        UPN of the line manager. The manager must exist and be enabled.
    .PARAMETER UsageLocation
        Two-letter ISO 3166-1 country code. Required before licences can be assigned.
    .PARAMETER CredentialHandler
        Optional script block called with (UserPrincipalName, SecureString) so the password can go
        straight to a secure channel or vault. When supplied, the password is not kept on the result.
    .PARAMETER ApprovalReference
        Ticket or HR reference authorising the change. Stored in the audit log.
    .EXAMPLE
        New-JmlJoiner -EmployeeId NW1001 -GivenName Alex -Surname Morgan -Department Finance `
            -JobTitle 'Finance Analyst' -ManagerUserPrincipalName sam.rivera@northwind.example `
            -UsageLocation GB -ApprovalReference HR-1001 -WhatIf
    .OUTPUTS
        Jml.Result with Status, Actions and (for a live run without -CredentialHandler) InitialPassword.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EmployeeId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$GivenName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Surname,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Department,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$JobTitle,
        [Parameter(Mandatory)][Alias('ManagerUpn')][ValidateNotNullOrEmpty()][string]$ManagerUserPrincipalName,
        [Parameter(Mandatory)][string]$UsageLocation,
        [string]$OfficeLocation,
        [Nullable[datetime]]$StartDate,
        [string]$ApprovalReference = '',
        [scriptblock]$CredentialHandler,
        [string]$ConfigPath,
        [string]$AuditLogPath,
        [string]$RunId
    )

    $config = Import-JmlConfig -Path $ConfigPath
    Assert-JmlGraphContext -Operation Joiner
    $dryRun = [bool]$WhatIfPreference
    $context = New-JmlContext -Operation 'Joiner' -Target "employee:$EmployeeId" -Cmdlet $PSCmdlet `
        -AuditLogPath (Resolve-JmlAuditPath -Config $config -AuditLogPath $AuditLogPath) `
        -DryRun $dryRun -ApprovalReference $ApprovalReference -RunId $RunId

    $startText = if ($StartDate) { $StartDate.ToString('yyyy-MM-dd') } else { '' }
    $null = Add-JmlRecord -Context $context -Action 'Start' -Result $(if ($dryRun) { 'WhatIf' } else { 'Succeeded' }) `
        -Detail @{ department = $Department; jobTitle = $JobTitle; startDate = $startText }

    # 1. Validate the HR record before any Graph call.
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($UsageLocation -notmatch '^[A-Za-z]{2}$') { $problems.Add('UsageLocation must be a two-letter country code such as GB.') }
    if ($GivenName -notmatch "^[\p{L}][\p{L}\p{M}'\-. ]{0,63}$") { $problems.Add('GivenName contains unsupported characters.') }
    if ($Surname -notmatch "^[\p{L}][\p{L}\p{M}'\-. ]{0,63}$") { $problems.Add('Surname contains unsupported characters.') }
    $desired = $null
    try { $desired = Get-JmlDesiredGroup -Config $config -Department $Department -JobTitle $JobTitle }
    catch { $problems.Add($_.Exception.Message) }
    if ($problems.Count -gt 0) {
        $null = Add-JmlRecord -Context $context -Action 'Validate' -Result 'Failed' -ErrorMessage ($problems -join ' ')
        return New-JmlResult -Context $context -Status 'Failed'
    }
    $UsageLocation = $UsageLocation.ToUpperInvariant()

    # 2. Manager must exist and be active.
    $manager = Resolve-JmlUser -UserPrincipalName $ManagerUserPrincipalName
    if (-not $manager) {
        $null = Add-JmlRecord -Context $context -Action 'ResolveManager' -Result 'Failed' -ErrorMessage 'Manager not found.' -Detail @{ manager = $ManagerUserPrincipalName }
        return New-JmlResult -Context $context -Status 'Failed'
    }
    if ((Get-JmlProperty $manager 'AccountEnabled' $true) -eq $false) {
        $null = Add-JmlRecord -Context $context -Action 'ResolveManager' -Result 'Failed' -ErrorMessage 'Manager account is disabled.' -Detail @{ manager = $ManagerUserPrincipalName }
        return New-JmlResult -Context $context -Status 'Failed'
    }
    $managerId = [string](Get-JmlProperty $manager 'Id' '')

    # 3. Find an existing account (idempotency) or choose a free user principal name.
    $existing = Resolve-JmlUser -EmployeeId $EmployeeId
    $state = @{ UserId = ''; UserPrincipalName = ''; Created = $false }
    $initialPassword = $null
    $membership = @()

    if ($existing) {
        $state.UserId = [string](Get-JmlProperty $existing 'Id' '')
        $state.UserPrincipalName = [string](Get-JmlProperty $existing 'UserPrincipalName' '')
        $context.Target = $state.UserPrincipalName
        $membership = @(Get-JmlMembership -UserId $state.UserId)
        $refusal = Test-JmlProtectedUser -Config $config -User $existing -Membership $membership
        if (-not $refusal -and (Get-JmlProperty $existing 'AccountEnabled' $true) -eq $false) {
            $refusal = 'Existing account is disabled. Re-hire needs a manual review, so the automation will not re-enable it.'
        }
        if ($refusal) {
            $null = Add-JmlRecord -Context $context -Action 'ProtectionCheck' -Result 'Refused' -ErrorMessage $refusal
            return New-JmlResult -Context $context -Status 'Refused'
        }
        $null = Add-JmlRecord -Context $context -Action 'FindExistingAccount' -Result 'NoChange' -Detail @{ reason = 'Account already exists; reconciling instead of creating.' }
    }
    else {
        $maxAttempts = [int](Get-JmlProperty $config.Naming 'maxCollisionAttempts' 20)
        $identity = $null
        for ($sequence = 1; $sequence -le $maxAttempts; $sequence++) {
            $candidate = New-JmlIdentity -Config $config -GivenName $GivenName -Surname $Surname -EmployeeId $EmployeeId -Sequence $sequence
            if (-not (Resolve-JmlUser -UserPrincipalName $candidate.UserPrincipalName)) { $identity = $candidate; break }
        }
        if (-not $identity) {
            $null = Add-JmlRecord -Context $context -Action 'ChooseUserPrincipalName' -Result 'Failed' -ErrorMessage "No free user principal name after $maxAttempts attempts."
            return New-JmlResult -Context $context -Status 'Failed'
        }
        $state.UserPrincipalName = $identity.UserPrincipalName
        $context.Target = $identity.UserPrincipalName

        $initialPassword = New-JmlPassword -Length ([int](Get-JmlSetting -Config $config -Name 'joiner.passwordLength'))
        $createStep = Invoke-JmlStep -Context $context -Action 'CreateUser' -Detail @{
            department = $Department; jobTitle = $JobTitle; usageLocation = $UsageLocation
            employeeId = $EmployeeId; passwordGenerated = $true; forceChangePasswordNextSignIn = $true
        } -Script {
            $plain = ConvertFrom-JmlSecureString -SecureString $initialPassword
            try {
                $body = @{
                    accountEnabled    = $true
                    displayName       = $identity.DisplayName
                    givenName         = $GivenName.Trim()
                    surname           = $Surname.Trim()
                    userPrincipalName = $identity.UserPrincipalName
                    mailNickname      = $identity.MailNickname
                    department        = $Department
                    jobTitle          = $JobTitle
                    usageLocation     = $UsageLocation
                    employeeId        = $EmployeeId
                    passwordProfile   = @{ forceChangePasswordNextSignIn = $true; password = $plain }
                }
                if ($OfficeLocation) { $body.officeLocation = $OfficeLocation }
                $created = New-MgUser -BodyParameter $body -ErrorAction Stop
                $state.UserId = [string](Get-JmlProperty $created 'Id' '')
                $state.Created = $true
            }
            finally { $plain = $null; $body = $null }
        }
        if ($createStep.Result -eq 'Failed') { return New-JmlResult -Context $context -Status 'Failed' }
        if ($createStep.Result -eq 'Declined') { return New-JmlResult -Context $context -Status 'Refused' }
        if ($dryRun) { $state.UserId = 'whatif-user-id' }
    }

    # 4. Attributes (only relevant when reconciling an existing account).
    if ($existing) {
        $wanted = @{ Department = $Department; JobTitle = $JobTitle; UsageLocation = $UsageLocation; OfficeLocation = $OfficeLocation }
        $changes = Get-JmlAttributeChange -User $existing -Wanted $wanted
        if ($changes.Count -gt 0) {
            $null = Invoke-JmlStep -Context $context -Action 'UpdateAttributes' -Detail @{ attributes = @($changes.Keys | Sort-Object) } -Script {
                Update-MgUser -UserId $state.UserId @changes -ErrorAction Stop
            }
        }
        else { $null = Add-JmlRecord -Context $context -Action 'UpdateAttributes' -Result 'NoChange' }
    }

    # 5. Manager.
    $currentManagerId = if ($existing) { Get-JmlManagerId -UserId $state.UserId } else { '' }
    if ($currentManagerId -ieq $managerId) {
        $null = Add-JmlRecord -Context $context -Action 'SetManager' -Result 'NoChange'
    }
    else {
        $null = Invoke-JmlStep -Context $context -Action 'SetManager' -Detail @{ manager = $ManagerUserPrincipalName } -Script {
            Invoke-JmlRetry -Script { Set-JmlManager -UserId $state.UserId -ManagerId $managerId }
        }
    }

    # 6. Groups, including the licence group for group-based licensing.
    $currentIds = @($membership | Where-Object Kind -eq 'Group' | ForEach-Object { $_.Id })
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
            try { Invoke-JmlRetry -Script { New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $state.UserId -ErrorAction Stop } }
            catch { if ($_.Exception.Message -notmatch '(?i)already exist') { throw } }
        }
    }

    # 7. Hand the one-time password over without logging it.
    $extra = @{ InitialPassword = $null; Created = $state.Created }
    if ($state.Created -and -not $dryRun -and $initialPassword) {
        if ($CredentialHandler) {
            $null = Invoke-JmlStep -Context $context -Action 'HandOverCredential' -Detail @{ method = 'CredentialHandler' } -Script {
                & $CredentialHandler $state.UserPrincipalName $initialPassword
            }
        }
        else { $extra.InitialPassword = $initialPassword }
    }

    New-JmlResult -Context $context -UserPrincipalName $state.UserPrincipalName -Extra $extra
}
