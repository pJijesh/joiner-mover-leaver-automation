BeforeAll { . (Join-Path $PSScriptRoot 'Common.ps1') }

Describe 'New-JmlJoiner' {
    BeforeEach {
        $script:T = New-FakeTenant
        Initialize-StandardTenant $script:T
        Register-FakeGraph
        $script:P = New-TestPaths
        $script:JoinerArgs = @{
            EmployeeId = 'NW1001'; GivenName = 'Alex'; Surname = 'Morgan'; Department = 'Finance'; JobTitle = 'Finance Analyst'
            ManagerUserPrincipalName = 'sam.rivera@northwind.example'; UsageLocation = 'GB'; ApprovalReference = 'HR-1001'
            ConfigPath = $script:ConfigPath; AuditLogPath = $script:P.Audit
        }
    }
    AfterEach { Remove-Item -LiteralPath $script:P.Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'changes nothing under -WhatIf but reports every planned action' {
        $r = New-JmlJoiner @script:JoinerArgs -WhatIf
        $r.Status | Should -Be 'WhatIf'
        $r.WhatIf | Should -BeTrue
        $script:T.Calls.Count | Should -Be 0
        $script:T.Users.Count | Should -Be 1
        ($r.Actions | Where-Object Action -eq 'CreateUser').Result | Should -Be 'WhatIf'
        ($r.Actions | Where-Object Action -eq 'AssignLicenceGroup').Target | Should -Be 'NW-Lic-Premium'
        $r.InitialPassword | Should -BeNullOrEmpty
    }

    It 'creates the user with forced password change, manager, attributes and the mapped groups' {
        $r = New-JmlJoiner @script:JoinerArgs -Confirm:$false
        $r.Status | Should -Be 'Succeeded'
        $r.UserPrincipalName | Should -Be 'alex.morgan@northwind.example'
        $body = $script:T.LastBody
        $body.passwordProfile.forceChangePasswordNextSignIn | Should -BeTrue
        $body.usageLocation | Should -Be 'GB'
        $body.department | Should -Be 'Finance'
        $body.employeeId | Should -Be 'NW1001'
        (Get-FakeGroupNames $script:T 'alex.morgan@northwind.example') | Should -Be @(
            'NW-All-Staff', 'NW-App-Accounting', 'NW-Dept-Finance', 'NW-Intranet-Readers', 'NW-Lic-Premium', 'NW-Role-Finance-Reporting')
        $alex = $script:T.Users.Values | Where-Object UserPrincipalName -eq 'alex.morgan@northwind.example'
        $sam = $script:T.Users.Values | Where-Object UserPrincipalName -eq 'sam.rivera@northwind.example'
        $script:T.Managers[$alex.Id] | Should -Be $sam.Id
    }

    It 'returns the one-time password only as a SecureString and never writes it to the audit log' {
        $r = New-JmlJoiner @script:JoinerArgs -Confirm:$false
        $r.InitialPassword | Should -BeOfType [System.Security.SecureString]
        $plain = $script:T.LastPassword
        $plain.Length | Should -BeGreaterOrEqual 20
        $raw = Get-Content -LiteralPath $script:P.Audit -Raw
        $raw | Should -Not -BeNullOrEmpty
        $raw.Contains($plain) | Should -BeFalse
        $raw | Should -Not -Match '(?i)"password"\s*:\s*"[^\[]'
        ($r | ConvertTo-Json -Depth 5 -WarningAction SilentlyContinue).Contains($plain) | Should -BeFalse
    }

    It 'hands the password to -CredentialHandler and keeps nothing on the result' {
        $script:Seen = $null
        $handler = { param($upn, $secure) $script:Seen = @{ Upn = $upn; Type = $secure.GetType().Name } }
        $r = New-JmlJoiner @script:JoinerArgs -Confirm:$false -CredentialHandler $handler
        $r.InitialPassword | Should -BeNullOrEmpty
        $script:Seen.Upn | Should -Be 'alex.morgan@northwind.example'
        $script:Seen.Type | Should -Be 'SecureString'
        ($r.Actions | Where-Object Action -eq 'HandOverCredential').Result | Should -Be 'Succeeded'
    }

    It 'is idempotent: a second run makes no further change' {
        $null = New-JmlJoiner @script:JoinerArgs -Confirm:$false
        $before = $script:T.Calls.Count
        $second = New-JmlJoiner @script:JoinerArgs -Confirm:$false
        $second.Status | Should -Be 'NoChange'
        $script:T.Calls.Count | Should -Be $before
        $second.InitialPassword | Should -BeNullOrEmpty
        @($script:T.Calls | Where-Object { $_ -like 'New-MgUser*' }).Count | Should -Be 1
    }

    It 'repairs an existing account that is missing groups, without recreating it' {
        $existing = Add-FakeUser -Tenant $script:T -Upn 'alex.morgan@northwind.example' -EmployeeId 'NW1001' -Department 'Finance' -JobTitle 'Finance Analyst'
        Add-FakeMember -Tenant $script:T -GroupName 'NW-All-Staff' -User $existing
        $r = New-JmlJoiner @script:JoinerArgs -Confirm:$false
        $r.Status | Should -Be 'Succeeded'
        @($script:T.Calls | Where-Object { $_ -like 'New-MgUser*' }).Count | Should -Be 0
        (Get-FakeGroupNames $script:T 'alex.morgan@northwind.example') | Should -Contain 'NW-Lic-Premium'
    }

    It 'resolves a user principal name collision by numbering' {
        $null = Add-FakeUser -Tenant $script:T -Upn 'alex.morgan@northwind.example' -EmployeeId 'NW0999' -Department 'Sales'
        $r = New-JmlJoiner @script:JoinerArgs -Confirm:$false
        $r.UserPrincipalName | Should -Be 'alex.morgan2@northwind.example'
    }

    It 'applies the department licence override (Warehouse uses the frontline licence group)' {
        $a = $script:JoinerArgs.Clone(); $a.Department = 'Warehouse'; $a.JobTitle = 'Picker'; $a.EmployeeId = 'NW1002'
        $null = New-JmlJoiner @a -Confirm:$false
        $groups = Get-FakeGroupNames $script:T 'alex.morgan@northwind.example'
        $groups | Should -Contain 'NW-Lic-Frontline'
        $groups | Should -Not -Contain 'NW-Lic-Premium'
    }

    It 'adds role groups only when the job title matches' {
        $a = $script:JoinerArgs.Clone(); $a.JobTitle = 'Finance Manager'
        $null = New-JmlJoiner @a -Confirm:$false
        $groups = Get-FakeGroupNames $script:T 'alex.morgan@northwind.example'
        $groups | Should -Contain 'NW-Role-Finance-Approvers'
        $groups | Should -Not -Contain 'NW-Role-Finance-Reporting'
    }

    It 'fails cleanly for an unmapped department without calling Graph writes' {
        $a = $script:JoinerArgs.Clone(); $a.Department = 'Marketing'
        $r = New-JmlJoiner @a -Confirm:$false
        $r.Status | Should -Be 'Failed'
        ($r.Actions | Where-Object Action -eq 'Validate').Error | Should -Match 'not mapped'
        $script:T.Calls.Count | Should -Be 0
    }

    It 'fails for an invalid usage location' {
        $a = $script:JoinerArgs.Clone(); $a.UsageLocation = 'United Kingdom'
        $r = New-JmlJoiner @a -Confirm:$false
        $r.Status | Should -Be 'Failed'
        $script:T.Calls.Count | Should -Be 0
    }

    It 'fails when the manager does not exist' {
        $a = $script:JoinerArgs.Clone(); $a.ManagerUserPrincipalName = 'nobody@northwind.example'
        $r = New-JmlJoiner @a -Confirm:$false
        $r.Status | Should -Be 'Failed'
        ($r.Actions | Where-Object Action -eq 'ResolveManager').Result | Should -Be 'Failed'
        $script:T.Calls.Count | Should -Be 0
    }

    It 'refuses to re-enable or touch an existing disabled account (re-hire needs review)' {
        $null = Add-FakeUser -Tenant $script:T -Upn 'alex.morgan@northwind.example' -EmployeeId 'NW1001' -Enabled $false
        $r = New-JmlJoiner @script:JoinerArgs -Confirm:$false
        $r.Status | Should -Be 'Refused'
        $script:T.Calls.Count | Should -Be 0
    }

    It 'skips dynamic and role-assignable groups instead of failing the whole joiner' {
        $null = Add-FakeGroup -Tenant $script:T -Name 'NW-App-Accounting' -Dynamic
        $script:T.Groups.Remove(($script:T.Groups.Values | Where-Object { $_.DisplayName -eq 'NW-App-Accounting' -and -not $_.GroupTypes.Count }).Id)
        $r = New-JmlJoiner @script:JoinerArgs -Confirm:$false
        $skipped = $r.Actions | Where-Object { $_.Target -eq 'NW-App-Accounting' }
        $skipped.Result | Should -Be 'Skipped'
        $skipped.Detail.reason | Should -Match 'Dynamic'
        $r.Status | Should -Be 'Succeeded'
    }

    It 'reports a missing group as a failed action and still completes the other steps' {
        $script:T.Groups.Remove(($script:T.Groups.Values | Where-Object DisplayName -eq 'NW-App-Accounting').Id)
        $r = New-JmlJoiner @script:JoinerArgs -Confirm:$false
        $r.Status | Should -Be 'PartiallySucceeded'
        (Get-FakeGroupNames $script:T 'alex.morgan@northwind.example') | Should -Contain 'NW-Dept-Finance'
    }

    It 'throws a clear error when not connected to Graph' {
        Mock -ModuleName JmlAutomation Get-MgContext { $null }
        { New-JmlJoiner @script:JoinerArgs -WhatIf } | Should -Throw '*Connect-JmlGraph*'
    }

    It 'throws when the connection lacks a required scope' {
        $script:T.Context.Scopes = @('User.Read.All')
        { New-JmlJoiner @script:JoinerArgs -WhatIf } | Should -Throw '*missing permissions*'
    }

    It 'writes one audit line per action with who, what, when and result' {
        $r = New-JmlJoiner @script:JoinerArgs -Confirm:$false
        $lines = Read-TestAudit $script:P.Audit
        $lines.Count | Should -BeGreaterThan 5
        $lines | ForEach-Object {
            $_.actor | Should -Be 'it.admin@northwind.example'
            $_.operation | Should -Be 'Joiner'
            $_.runId | Should -Be $r.RunId
            $_.approvalReference | Should -Be 'HR-1001'
            { [datetime]::Parse($_.timestampUtc) } | Should -Not -Throw
        }
        ($lines | Where-Object action -eq 'CreateUser').result | Should -Be 'Succeeded'
    }

    It 'records a failed create without leaking details and stops' {
        Mock -ModuleName JmlAutomation New-MgUser { throw 'Request_BadRequest: The specified password does not comply with password complexity requirements.' }
        $r = New-JmlJoiner @script:JoinerArgs -Confirm:$false
        $r.Status | Should -Be 'Failed'
        ($r.Actions | Where-Object Action -eq 'CreateUser').Result | Should -Be 'Failed'
        @($r.Actions | Where-Object Action -eq 'AddToGroup').Count | Should -Be 0
    }
}
