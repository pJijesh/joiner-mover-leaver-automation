BeforeAll { . (Join-Path $PSScriptRoot 'Common.ps1') }

Describe 'Move-JmlUser' {
    BeforeEach {
        $script:T = New-FakeTenant
        Initialize-StandardTenant $script:T
        $null = Add-FakeUser -Tenant $script:T -Upn 'jordan.blake@northwind.example' -Name 'Jordan Blake' -EmployeeId 'NW0002' -Department 'Sales' -JobTitle 'Sales Manager'
        # A finance analyst holding the groups the joiner process would have given them, plus one manual group.
        $script:Alex = Add-FakeUser -Tenant $script:T -Upn 'alex.morgan@northwind.example' -Name 'Alex Morgan' -EmployeeId 'NW1001' `
            -Department 'Finance' -JobTitle 'Finance Analyst' -Manager 'sam.rivera@northwind.example'
        $null = Add-FakeGroup -Tenant $script:T -Name 'Project-Phoenix-Team'
        foreach ($g in 'NW-All-Staff', 'NW-Intranet-Readers', 'NW-Dept-Finance', 'NW-App-Accounting', 'NW-Role-Finance-Reporting', 'NW-Lic-Premium', 'Project-Phoenix-Team') {
            Add-FakeMember -Tenant $script:T -GroupName $g -User $script:Alex
        }
        Register-FakeGraph
        $script:P = New-TestPaths
        $script:MoveArgs = @{
            UserPrincipalName = 'alex.morgan@northwind.example'; Department = 'Sales'; JobTitle = 'Sales Manager'
            ApprovalReference = 'HR-2044'; ConfigPath = $script:ConfigPath; AuditLogPath = $script:P.Audit
        }
    }
    AfterEach { Remove-Item -LiteralPath $script:P.Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'changes nothing under -WhatIf but lists every planned change' {
        $before = Get-FakeGroupNames $script:T 'alex.morgan@northwind.example'
        $r = Move-JmlUser @script:MoveArgs -WhatIf
        $r.Status | Should -Be 'WhatIf'
        $script:T.Calls.Count | Should -Be 0
        Get-FakeGroupNames $script:T 'alex.morgan@northwind.example' | Should -Be $before
        ($r.Actions | Where-Object Action -eq 'UpdateAttributes').Result | Should -Be 'WhatIf'
        ($r.Actions | Where-Object { $_.Action -eq 'RemoveFromGroup' -and $_.Target -eq 'NW-Dept-Finance' }).Result | Should -Be 'WhatIf'
    }

    It 'swaps department, role and licence groups, keeps the baseline and leaves manual groups alone' {
        $r = Move-JmlUser @script:MoveArgs -Confirm:$false
        $r.Status | Should -Be 'Succeeded'
        $groups = Get-FakeGroupNames $script:T 'alex.morgan@northwind.example'
        $groups | Should -Be @('NW-All-Staff', 'NW-App-CRM', 'NW-Dept-Sales', 'NW-Intranet-Readers', 'NW-Lic-Standard', 'NW-Role-Sales-Forecast-Viewers', 'Project-Phoenix-Team')
        $alex = $script:T.Users[$script:Alex.Id]
        $alex.Department | Should -Be 'Sales'
        $alex.JobTitle | Should -Be 'Sales Manager'
    }

    It 'adds the new licence group before removing the old one so licensing never has a gap' {
        $null = Move-JmlUser @script:MoveArgs -Confirm:$false
        $add = [array]::IndexOf($script:T.Calls.ToArray(), 'New-MgGroupMember:NW-Lic-Standard:alex.morgan@northwind.example')
        $remove = [array]::IndexOf($script:T.Calls.ToArray(), 'Remove-MgGroupMemberByRef:NW-Lic-Premium:alex.morgan@northwind.example')
        $add | Should -BeGreaterOrEqual 0
        $remove | Should -BeGreaterThan $add
    }

    It 'is idempotent: a second run changes nothing' {
        $null = Move-JmlUser @script:MoveArgs -Confirm:$false
        $calls = $script:T.Calls.Count
        $second = Move-JmlUser @script:MoveArgs -Confirm:$false
        $second.Status | Should -Be 'NoChange'
        $script:T.Calls.Count | Should -Be $calls
    }

    It 'handles a job title change on its own by swapping only the role group' {
        $r = Move-JmlUser -UserPrincipalName 'alex.morgan@northwind.example' -JobTitle 'Finance Manager' -ConfigPath $script:ConfigPath -AuditLogPath $script:P.Audit -Confirm:$false
        $r.Status | Should -Be 'Succeeded'
        $groups = Get-FakeGroupNames $script:T 'alex.morgan@northwind.example'
        $groups | Should -Contain 'NW-Role-Finance-Approvers'
        $groups | Should -Not -Contain 'NW-Role-Finance-Reporting'
        $groups | Should -Contain 'NW-Dept-Finance'
        $groups | Should -Contain 'Project-Phoenix-Team'
    }

    It 'sets a new manager and skips the call when the manager is unchanged' {
        $r = Move-JmlUser -UserPrincipalName 'alex.morgan@northwind.example' -ManagerUserPrincipalName 'jordan.blake@northwind.example' -ConfigPath $script:ConfigPath -AuditLogPath $script:P.Audit -Confirm:$false
        ($r.Actions | Where-Object Action -eq 'SetManager').Result | Should -Be 'Succeeded'
        $jordan = $script:T.Users.Values | Where-Object UserPrincipalName -eq 'jordan.blake@northwind.example'
        $script:T.Managers[$script:Alex.Id] | Should -Be $jordan.Id
        $again = Move-JmlUser -UserPrincipalName 'alex.morgan@northwind.example' -ManagerUserPrincipalName 'jordan.blake@northwind.example' -ConfigPath $script:ConfigPath -AuditLogPath $script:P.Audit -Confirm:$false
        ($again.Actions | Where-Object Action -eq 'SetManager').Result | Should -Be 'NoChange'
    }

    It 'fails and changes nothing when the new manager does not exist' {
        $r = Move-JmlUser -UserPrincipalName 'alex.morgan@northwind.example' -Department 'Sales' -ManagerUserPrincipalName 'nobody@northwind.example' -ConfigPath $script:ConfigPath -AuditLogPath $script:P.Audit -Confirm:$false
        $r.Status | Should -Be 'Failed'
        $script:T.Calls.Count | Should -Be 0
    }

    It 'fails when no change is requested' {
        $r = Move-JmlUser -UserPrincipalName 'alex.morgan@northwind.example' -ConfigPath $script:ConfigPath -AuditLogPath $script:P.Audit -Confirm:$false
        $r.Status | Should -Be 'Failed'
        ($r.Actions | Where-Object Action -eq 'Validate').Error | Should -Match 'at least one'
    }

    It 'fails when the user does not exist' {
        $r = Move-JmlUser -UserPrincipalName 'ghost@northwind.example' -Department 'Sales' -ConfigPath $script:ConfigPath -AuditLogPath $script:P.Audit -Confirm:$false
        $r.Status | Should -Be 'Failed'
        ($r.Actions | Where-Object Action -eq 'ResolveUser').Error | Should -Be 'User not found.'
    }

    It 'fails for a department that is not in the mapping and changes nothing' {
        $a = $script:MoveArgs.Clone(); $a.Department = 'Marketing'
        $r = Move-JmlUser @a -Confirm:$false
        $r.Status | Should -Be 'Failed'
        $script:T.Calls.Count | Should -Be 0
    }

    It 'skips a dynamic group it should remove and reports why' {
        # Replace the static group with a dynamic one of the same name.
        $static = $script:T.Groups.Values | Where-Object DisplayName -eq 'NW-App-Accounting'
        $script:T.Groups.Remove($static.Id)
        $null = Add-FakeGroup -Tenant $script:T -Name 'NW-App-Accounting' -Dynamic
        Add-FakeMember -Tenant $script:T -GroupName 'NW-App-Accounting' -User $script:Alex
        $r = Move-JmlUser @script:MoveArgs -Confirm:$false
        $entry = $r.Actions | Where-Object { $_.Action -eq 'RemoveFromGroup' -and $_.Target -eq 'NW-App-Accounting' }
        $entry.Result | Should -Be 'Skipped'
        $entry.Detail.reason | Should -Match 'Dynamic'
        $r.Status | Should -Be 'Succeeded'
    }

    It 'reports a failed group removal without abandoning the other changes' {
        Mock -ModuleName JmlAutomation Remove-MgGroupMemberByRef { throw 'Authorization_RequestDenied: Insufficient privileges.' } -ParameterFilter { $true }
        $r = Move-JmlUser @script:MoveArgs -Confirm:$false
        $r.Status | Should -Be 'PartiallySucceeded'
        $r.FailedCount | Should -BeGreaterThan 0
        Get-FakeGroupNames $script:T 'alex.morgan@northwind.example' | Should -Contain 'NW-Dept-Sales'
    }

    Context 'protection rules' {
        It 'refuses a break-glass account matched by pattern' {
            $null = Add-FakeUser -Tenant $script:T -Upn 'breakglass03@northwind.example' -Department 'IT'
            $r = Move-JmlUser -UserPrincipalName 'breakglass03@northwind.example' -Department 'Sales' -ConfigPath $script:ConfigPath -AuditLogPath $script:P.Audit -Confirm:$false
            $r.Status | Should -Be 'Refused'
            ($r.Actions | Where-Object Action -eq 'ProtectionCheck').Error | Should -Match 'protected pattern'
            $script:T.Calls.Count | Should -Be 0
        }
        It 'refuses an account listed by name' {
            $null = Add-FakeUser -Tenant $script:T -Upn 'breakglass01@northwind.example'
            $r = Move-JmlUser -UserPrincipalName 'breakglass01@northwind.example' -Department 'Sales' -ConfigPath $script:ConfigPath -AuditLogPath $script:P.Audit -Confirm:$false
            $r.Status | Should -Be 'Refused'
        }
        It 'refuses a holder of an Entra administrator role' {
            $script:T.Roles[$script:Alex.Id] = @('Global Administrator')
            $r = Move-JmlUser @script:MoveArgs -Confirm:$false
            $r.Status | Should -Be 'Refused'
            ($r.Actions | Where-Object Action -eq 'ProtectionCheck').Error | Should -Match 'administrator'
            $script:T.Calls.Count | Should -Be 0
        }
        It 'refuses a member of a protected group' {
            Add-FakeMember -Tenant $script:T -GroupName 'NW-Privileged-Admins' -User $script:Alex
            $r = Move-JmlUser @script:MoveArgs -Confirm:$false
            $r.Status | Should -Be 'Refused'
            ($r.Actions | Where-Object Action -eq 'ProtectionCheck').Error | Should -Match 'NW-Privileged-Admins'
        }
        It 'refuses an account synced from on-premises Active Directory' {
            $null = Add-FakeUser -Tenant $script:T -Upn 'synced.user@northwind.example' -Department 'Finance' -Synced $true
            $r = Move-JmlUser -UserPrincipalName 'synced.user@northwind.example' -Department 'Sales' -ConfigPath $script:ConfigPath -AuditLogPath $script:P.Audit -Confirm:$false
            $r.Status | Should -Be 'Refused'
        }
        It 'refuses a disabled account' {
            $script:T.Users[$script:Alex.Id].AccountEnabled = $false
            $r = Move-JmlUser @script:MoveArgs -Confirm:$false
            $r.Status | Should -Be 'Refused'
        }
        It 'refuses the account that is running the automation' {
            $script:T.Context.Account = 'alex.morgan@northwind.example'
            $r = Move-JmlUser @script:MoveArgs -Confirm:$false
            $r.Status | Should -Be 'Refused'
            ($r.Actions | Where-Object Action -eq 'ProtectionCheck').Error | Should -Match 'running the automation'
        }
    }

    It 'records the approval reference and actor on every audit line' {
        $null = Move-JmlUser @script:MoveArgs -Confirm:$false
        $lines = Read-TestAudit $script:P.Audit
        $lines.Count | Should -BeGreaterThan 3
        $lines | ForEach-Object { $_.operation | Should -Be 'Mover'; $_.approvalReference | Should -Be 'HR-2044'; $_.actor | Should -Be 'it.admin@northwind.example' }
    }
}
