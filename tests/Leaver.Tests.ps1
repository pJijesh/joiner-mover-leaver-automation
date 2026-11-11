BeforeAll { . (Join-Path $PSScriptRoot 'Common.ps1') }

Describe 'Remove-JmlLeaver' {
    BeforeEach {
        $script:T = New-FakeTenant
        Initialize-StandardTenant $script:T
        $script:Jamie = Add-FakeUser -Tenant $script:T -Upn 'jamie.okafor@northwind.example' -Name 'Jamie Okafor' -EmployeeId 'NW1500' `
            -Department 'Finance' -JobTitle 'Finance Analyst' -Manager 'sam.rivera@northwind.example' -DirectSkus @('sku-direct-1')
        $script:Report = Add-FakeUser -Tenant $script:T -Upn 'riley.chen@northwind.example' -Name 'Riley Chen' -EmployeeId 'NW1501' -Manager 'jamie.okafor@northwind.example'
        $null = Add-FakeGroup -Tenant $script:T -Name 'Everyone-Mailing-List' -MailEnabled
        $null = Add-FakeGroup -Tenant $script:T -Name 'Project-Phoenix-Team'
        foreach ($g in 'NW-All-Staff', 'NW-Intranet-Readers', 'NW-Dept-Finance', 'NW-App-Accounting', 'NW-Role-Finance-Reporting', 'NW-Lic-Premium', 'Everyone-Mailing-List', 'Project-Phoenix-Team') {
            Add-FakeMember -Tenant $script:T -GroupName $g -User $script:Jamie
        }
        Add-FakeMethod -Tenant $script:T -User $script:Jamie -Type 'microsoftAuthenticatorAuthenticationMethod'
        Add-FakeMethod -Tenant $script:T -User $script:Jamie -Type 'phoneAuthenticationMethod'
        Register-FakeGraph
        $script:P = New-TestPaths
        $script:LeaveArgs = @{
            UserPrincipalName = 'jamie.okafor@northwind.example'; LeaveDate = [datetime]'2026-12-18'; ApprovalReference = 'HR-3101'
            ConfigPath = $script:ConfigPath; AuditLogPath = $script:P.Audit; OutputPath = $script:P.Output
        }
        function script:Get-Jamie { $script:T.Users[$script:Jamie.Id] }
        function script:Get-JamieGroups { Get-FakeGroupNames $script:T 'jamie.okafor@northwind.example' }
    }
    AfterEach { Remove-Item -LiteralPath $script:P.Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'changes nothing under -WhatIf, but still writes a clearly marked preview checklist' {
        $groupsBefore = Get-JamieGroups
        $r = Remove-JmlLeaver @script:LeaveArgs -WhatIf
        $r.Status | Should -Be 'WhatIf'
        $script:T.Calls.Count | Should -Be 0
        (Get-Jamie).AccountEnabled | Should -BeTrue
        Get-JamieGroups | Should -Be $groupsBefore
        $script:T.Methods[$script:Jamie.Id].Count | Should -Be 2
        Test-Path -LiteralPath $r.ChecklistPath | Should -BeTrue
        (Get-Content -LiteralPath $r.ChecklistPath -Raw) | Should -Match 'DRY RUN PREVIEW'
    }

    It 'disables sign-in, revokes sessions, removes methods and groups, and holds licences until the mailbox is converted' {
        $r = Remove-JmlLeaver @script:LeaveArgs -Confirm:$false
        $r.Status | Should -Be 'Succeeded'
        (Get-Jamie).AccountEnabled | Should -BeFalse
        $script:T.Calls | Should -Contain 'Revoke-MgUserSignInSession:jamie.okafor@northwind.example'
        $script:T.Methods[$script:Jamie.Id].Count | Should -Be 0
        # Licence group is held, other managed and unmanaged groups are removed, the mail-enabled list is left for Exchange.
        Get-JamieGroups | Should -Be @('Everyone-Mailing-List', 'NW-Lic-Premium')
        $r.LicencesHeld | Should -BeTrue
        (Get-Jamie).LicenseAssignmentStates.Count | Should -Be 1
        ($r.Actions | Where-Object Action -eq 'RemoveDirectLicences').Result | Should -Be 'Skipped'
        @($script:T.Calls | Where-Object { $_ -like 'Set-MgUserLicense*' }).Count | Should -Be 0
    }

    It 'releases the group licence and direct licences when -MailboxConverted is supplied' {
        $r = Remove-JmlLeaver @script:LeaveArgs -MailboxConverted -Confirm:$false
        $r.Status | Should -Be 'Succeeded'
        Get-JamieGroups | Should -Be @('Everyone-Mailing-List')
        (Get-Jamie).LicenseAssignmentStates.Count | Should -Be 0
        $r.LicencesHeld | Should -BeFalse
        $script:T.Calls | Should -Contain 'Set-MgUserLicense:jamie.okafor@northwind.example:remove=1'
    }

    It 'removes the password-free authentication methods and never tries to delete the password method' {
        $null = Remove-JmlLeaver @script:LeaveArgs -Confirm:$false
        $script:T.Calls | Should -Contain 'Remove-MethodType:#microsoft.graph.microsoftAuthenticatorAuthenticationMethod'
        $script:T.Calls | Should -Contain 'Remove-MethodType:#microsoft.graph.phoneAuthenticationMethod'
        @($script:T.Calls | Where-Object { $_ -like '*password*' }).Count | Should -Be 0
    }

    It 'leaves authentication methods in place with -SkipMfaReset' {
        $r = Remove-JmlLeaver @script:LeaveArgs -SkipMfaReset -Confirm:$false
        $script:T.Methods[$script:Jamie.Id].Count | Should -Be 2
        ($r.Actions | Where-Object Action -eq 'ResetMfaMethods').Result | Should -Be 'Skipped'
    }

    It 'treats a default authentication method that Entra will not delete as skipped, not failed' {
        $script:T.Methods[$script:Jamie.Id][1].AdditionalProperties['default'] = $true
        $r = Remove-JmlLeaver @script:LeaveArgs -Confirm:$false
        $r.Status | Should -Be 'Succeeded'
        $phone = $r.Actions | Where-Object { $_.Action -eq 'RemoveAuthenticationMethod' -and $_.Target -like 'phone:*' }
        $phone.Result | Should -Be 'Skipped'
        $phone.Detail.reason | Should -Match 'default'
    }

    It 'is idempotent: running again makes no further group or account change' {
        $null = Remove-JmlLeaver @script:LeaveArgs -MailboxConverted -Confirm:$false
        $calls = @($script:T.Calls | Where-Object { $_ -notlike 'Revoke-MgUserSignInSession*' }).Count
        $second = Remove-JmlLeaver @script:LeaveArgs -MailboxConverted -Confirm:$false
        $second.Status | Should -Be 'Succeeded'
        @($script:T.Calls | Where-Object { $_ -notlike 'Revoke-MgUserSignInSession*' }).Count | Should -Be $calls
        ($second.Actions | Where-Object Action -eq 'DisableAccount').Result | Should -Be 'NoChange'
        ($second.Actions | Where-Object Action -eq 'RemoveDirectLicences').Result | Should -Be 'NoChange'
    }

    It 'only removes managed groups when groupRemoval is ManagedOnly' {
        $custom = Join-Path $script:P.Root 'config'
        Copy-Item -LiteralPath $script:ConfigPath -Destination $custom -Recurse
        $settingsFile = Join-Path $custom 'settings.json'
        (Get-Content -LiteralPath $settingsFile -Raw).Replace('"groupRemoval": "All"', '"groupRemoval": "ManagedOnly"') | Set-Content -LiteralPath $settingsFile -Encoding utf8
        $a = $script:LeaveArgs.Clone(); $a.ConfigPath = $custom
        $r = Remove-JmlLeaver @a -MailboxConverted -Confirm:$false
        Get-JamieGroups | Should -Be @('Everyone-Mailing-List', 'Project-Phoenix-Team')
        (Get-Content -LiteralPath $r.ChecklistPath -Raw) | Should -Match 'Project-Phoenix-Team: outside managed set'
    }

    It 'writes a checklist with manual steps, direct reports and skipped groups, and no secrets' {
        $r = Remove-JmlLeaver @script:LeaveArgs -Confirm:$false
        $text = Get-Content -LiteralPath $r.ChecklistPath -Raw
        $text | Should -Match 'LIVE RUN'
        $text | Should -Match 'shared mailbox'
        $text | Should -Match 'Riley Chen \(riley.chen@northwind.example\)'
        $text | Should -Match 'Sam Rivera \(sam.rivera@northwind.example\)'
        $text | Should -Match 'Everyone-Mailing-List: Distribution list'
        $text | Should -Match 'HR-3101'
        $text | Should -Match '2026-12-18'
        $text | Should -Not -Match '(?i)password\s*[:=]'
        (Split-Path $r.ChecklistPath -Leaf) | Should -Be 'leaver-checklist-jamie.okafor-20261218.md'
    }

    It 'fails for a user that does not exist and writes no checklist' {
        $a = $script:LeaveArgs.Clone(); $a.UserPrincipalName = 'ghost@northwind.example'
        $r = Remove-JmlLeaver @a -Confirm:$false
        $r.Status | Should -Be 'Failed'
        Test-Path -LiteralPath $script:P.Output | Should -BeFalse
    }

    It 'carries on and reports a partial result when session revocation fails' {
        Mock -ModuleName JmlAutomation Revoke-MgUserSignInSession { throw 'Authorization_RequestDenied: Insufficient privileges to complete the operation.' }
        $r = Remove-JmlLeaver @script:LeaveArgs -Confirm:$false
        $r.Status | Should -Be 'PartiallySucceeded'
        (Get-Jamie).AccountEnabled | Should -BeFalse
        ($r.Actions | Where-Object Action -eq 'RevokeSessions').Result | Should -Be 'Failed'
        $r.FailedCount | Should -Be 1
    }

    Context 'protection rules' {
        It 'refuses break-glass accounts by pattern and by name, and changes nothing' {
            foreach ($upn in 'breakglass01@northwind.example', 'svc-backup@northwind.example', 'admin-ops@northwind.example') {
                $null = Add-FakeUser -Tenant $script:T -Upn $upn
                $a = $script:LeaveArgs.Clone(); $a.UserPrincipalName = $upn
                (Remove-JmlLeaver @a -Confirm:$false).Status | Should -Be 'Refused'
            }
            $script:T.Calls.Count | Should -Be 0
        }
        It 'refuses an Entra administrator role holder' {
            $script:T.Roles[$script:Jamie.Id] = @('User Administrator')
            $r = Remove-JmlLeaver @script:LeaveArgs -Confirm:$false
            $r.Status | Should -Be 'Refused'
            (Get-Jamie).AccountEnabled | Should -BeTrue
        }
        It 'refuses a member of a protected group' {
            Add-FakeMember -Tenant $script:T -GroupName 'NW-BreakGlass-Exclusion' -User $script:Jamie
            (Remove-JmlLeaver @script:LeaveArgs -Confirm:$false).Status | Should -Be 'Refused'
        }
        It 'refuses an on-premises synced account' {
            $script:T.Users[$script:Jamie.Id].OnPremisesSyncEnabled = $true
            (Remove-JmlLeaver @script:LeaveArgs -Confirm:$false).Status | Should -Be 'Refused'
        }
        It 'refuses the account that is running the automation' {
            $script:T.Context.Account = 'jamie.okafor@northwind.example'
            (Remove-JmlLeaver @script:LeaveArgs -Confirm:$false).Status | Should -Be 'Refused'
        }
        It 'does not write a checklist for a refused account' {
            $script:T.Roles[$script:Jamie.Id] = @('User Administrator')
            $null = Remove-JmlLeaver @script:LeaveArgs -Confirm:$false
            Test-Path -LiteralPath $script:P.Output | Should -BeFalse
        }
    }

    It 'needs a connection that includes the leaver scopes' {
        $script:T.Context.Scopes = @('User.ReadWrite.All', 'GroupMember.ReadWrite.All', 'Group.Read.All')
        { Remove-JmlLeaver @script:LeaveArgs -WhatIf } | Should -Throw '*UserAuthenticationMethod.ReadWrite.All*'
    }

    It 'writes audit lines that carry the approval reference and the dry-run flag' {
        $null = Remove-JmlLeaver @script:LeaveArgs -WhatIf
        $lines = Read-TestAudit $script:P.Audit
        $lines.Count | Should -BeGreaterThan 5
        $lines | ForEach-Object { $_.whatIf | Should -BeTrue; $_.approvalReference | Should -Be 'HR-3101'; $_.operation | Should -Be 'Leaver' }
    }
}
