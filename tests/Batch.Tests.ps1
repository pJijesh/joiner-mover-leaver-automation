BeforeAll {
    . (Join-Path $PSScriptRoot 'Common.ps1')
    $script:Header = 'EventType,EffectiveDate,ApprovalReference,EmployeeId,UserPrincipalName,GivenName,Surname,Department,JobTitle,ManagerUpn,UsageLocation,OfficeLocation,MailboxConverted'
    $script:SamplePath = Join-Path $script:RepoRoot 'samples/events.sample.csv'

    function script:Initialize-SampleTenant {
        # The people the sample files refer to, in the state HR would expect to find them.
        param($Tenant)
        Initialize-StandardTenant $Tenant
        $null = Add-FakeUser -Tenant $Tenant -Upn 'jordan.blake@northwind.example' -Name 'Jordan Blake' -EmployeeId 'NW0002' -Department 'Operations' -JobTitle 'Operations Supervisor'
        $robin = Add-FakeUser -Tenant $Tenant -Upn 'robin.patel@northwind.example' -Name 'Robin Patel' -EmployeeId 'NW1100' -Department 'Finance' -JobTitle 'Finance Analyst' -Manager 'sam.rivera@northwind.example'
        foreach ($g in 'NW-All-Staff', 'NW-Intranet-Readers', 'NW-Dept-Finance', 'NW-App-Accounting', 'NW-Role-Finance-Reporting', 'NW-Lic-Premium') { Add-FakeMember -Tenant $Tenant -GroupName $g -User $robin }
        $taylor = Add-FakeUser -Tenant $Tenant -Upn 'taylor.reid@northwind.example' -Name 'Taylor Reid' -EmployeeId 'NW1101' -Department 'Operations' -JobTitle 'Operations Coordinator' -Manager 'jordan.blake@northwind.example'
        foreach ($g in 'NW-All-Staff', 'NW-Intranet-Readers', 'NW-Dept-Operations', 'NW-App-Dispatch', 'NW-Role-Ops-Coordinators', 'NW-Lic-Standard') { Add-FakeMember -Tenant $Tenant -GroupName $g -User $taylor }
        $jamie = Add-FakeUser -Tenant $Tenant -Upn 'jamie.okafor@northwind.example' -Name 'Jamie Okafor' -EmployeeId 'NW1102' -Department 'Finance' -JobTitle 'Finance Manager' -Manager 'sam.rivera@northwind.example'
        foreach ($g in 'NW-All-Staff', 'NW-Dept-Finance', 'NW-Lic-Premium') { Add-FakeMember -Tenant $Tenant -GroupName $g -User $jamie }
        Add-FakeMethod -Tenant $Tenant -User $jamie -Type 'phoneAuthenticationMethod'
        $casey = Add-FakeUser -Tenant $Tenant -Upn 'casey.nguyen@northwind.example' -Name 'Casey Nguyen' -EmployeeId 'NW1103' -Department 'Sales' -JobTitle 'Sales Executive' -DirectSkus @('sku-direct-1')
        foreach ($g in 'NW-All-Staff', 'NW-Dept-Sales', 'NW-Lic-Standard') { Add-FakeMember -Tenant $Tenant -GroupName $g -User $casey }
        $null = Add-FakeUser -Tenant $Tenant -Upn 'breakglass01@northwind.example' -Name 'Emergency Access 01' -Department 'IT'
    }

    function script:Write-TestCsv {
        param([string]$Path, [string[]]$Rows)
        Set-Content -LiteralPath $Path -Value (@($script:Header) + $Rows) -Encoding utf8
    }
}

Describe 'Invoke-JmlBatch' {
    BeforeEach {
        $script:T = New-FakeTenant
        Initialize-SampleTenant $script:T
        Register-FakeGraph
        $script:P = New-TestPaths
        $script:Common = @{ ConfigPath = $script:ConfigPath; AuditLogPath = $script:P.Audit; OutputPath = $script:P.Output; AsOfDate = [datetime]'2026-12-01'; WarningAction = 'SilentlyContinue' }
        $script:Csv = Join-Path $script:P.Root 'events.csv'
    }
    AfterEach { Remove-Item -LiteralPath $script:P.Root -Recurse -Force -ErrorAction SilentlyContinue }

    Context 'dry run (the default)' {
        It 'changes nothing and says so when -Execute is not passed' {
            $r = Invoke-JmlBatch -Path $script:SamplePath @script:Common
            $r.Mode | Should -Be 'DryRun'
            $script:T.Calls.Count | Should -Be 0
            $script:T.Users.Count | Should -BeGreaterThan 5
            @($script:T.Users.Values | Where-Object UserPrincipalName -like 'priya*').Count | Should -Be 0
        }

        It 'classifies every sample row: planned, deferred, refused and invalid' {
            $r = Invoke-JmlBatch -Path $script:SamplePath @script:Common
            $r.Results.Count | Should -Be 10
            $r.Counts.WhatIf | Should -Be 7
            $r.Counts.Deferred | Should -Be 1
            $r.Counts.Refused | Should -Be 1
            $r.Counts.Invalid | Should -Be 1
            ($r.Results | Where-Object { $_.Detail -match 'Not due until 2027-01-29' }).EventType | Should -Be 'Joiner'
            ($r.Results | Where-Object Status -eq 'Invalid').Detail | Should -Match 'UsageLocation is required'
            ($r.Results | Where-Object { $_.Target -eq 'breakglass01@northwind.example' }).Status | Should -Be 'Refused'
        }

        It 'plans the right user principal name for a name with an accent and an apostrophe' {
            $r = Invoke-JmlBatch -Path $script:SamplePath @script:Common
            ($r.Results | Where-Object { $_.Target -like 'zoe.*' }).Target | Should -Be 'zoe.oneil@northwind.example'
        }

        It 'flags every audit line as a dry run' {
            $null = Invoke-JmlBatch -Path $script:SamplePath @script:Common
            $lines = Read-TestAudit $script:P.Audit
            $lines.Count | Should -BeGreaterThan 20
            @($lines | Where-Object { -not $_.whatIf }).Count | Should -Be 0
            @($lines | Select-Object -ExpandProperty runId -Unique).Count | Should -Be 1
        }

        It 'treats -Execute together with -WhatIf as a dry run' {
            $r = Invoke-JmlBatch -Path $script:SamplePath @script:Common -Execute -WhatIf
            $r.Mode | Should -Be 'DryRun'
            $script:T.Calls.Count | Should -Be 0
        }

        It 'warns, but does not stop, when the file would breach a limit that -Execute enforces' {
            $custom = Join-Path $script:P.Root 'config'
            Copy-Item -LiteralPath $script:ConfigPath -Destination $custom -Recurse
            $f = Join-Path $custom 'settings.json'
            (Get-Content -LiteralPath $f -Raw).Replace('"maxEventsPerRun": 25', '"maxEventsPerRun": 3') | Set-Content -LiteralPath $f -Encoding utf8
            $a = $script:Common.Clone(); $a.ConfigPath = $custom
            $r = Invoke-JmlBatch -Path $script:SamplePath @a -WarningVariable warned -WarningAction SilentlyContinue
            $r.Mode | Should -Be 'DryRun'
            ($warned -join ' ') | Should -Match 'maxEventsPerRun'
        }
    }

    Context 'execute' {
        It 'applies joiners, movers and leavers, and refuses the protected account' {
            $script:Passwords = [System.Collections.Generic.List[string]]::new()
            $handler = { param($upn, $secure) $script:Passwords.Add([System.Net.NetworkCredential]::new('', $secure).Password) }
            $r = Invoke-JmlBatch -Path $script:SamplePath @script:Common -Execute -CredentialHandler $handler
            $r.Mode | Should -Be 'Execute'
            $r.Counts.Succeeded | Should -Be 7
            $r.Counts.Refused | Should -Be 1
            $r.Counts.Invalid | Should -Be 1
            $r.Counts.Deferred | Should -Be 1

            # Joiners
            Get-FakeGroupNames $script:T 'priya.nair@northwind.example' | Should -Contain 'NW-Lic-Premium'
            Get-FakeGroupNames $script:T 'tomasz.kowalski@northwind.example' | Should -Contain 'NW-Lic-Frontline'
            Get-FakeGroupNames $script:T 'zoe.oneil@northwind.example' | Should -Contain 'NW-Role-Ops-Coordinators'
            @($script:T.Users.Values | Where-Object UserPrincipalName -like 'mei.*').Count | Should -Be 0
            # Movers
            Get-FakeGroupNames $script:T 'robin.patel@northwind.example' | Should -Contain 'NW-Role-Sales-Forecast-Viewers'
            Get-FakeGroupNames $script:T 'robin.patel@northwind.example' | Should -Not -Contain 'NW-Dept-Finance'
            Get-FakeGroupNames $script:T 'taylor.reid@northwind.example' | Should -Contain 'NW-Role-Ops-Supervisors'
            Get-FakeGroupNames $script:T 'taylor.reid@northwind.example' | Should -Not -Contain 'NW-Role-Ops-Coordinators'
            # Leavers: first has not converted the mailbox so keeps the licence group, second has.
            ($script:T.Users.Values | Where-Object UserPrincipalName -eq 'jamie.okafor@northwind.example').AccountEnabled | Should -BeFalse
            Get-FakeGroupNames $script:T 'jamie.okafor@northwind.example' | Should -Be @('NW-Lic-Premium')
            Get-FakeGroupNames $script:T 'casey.nguyen@northwind.example' | Should -BeNullOrEmpty
            # The protected account was not touched.
            ($script:T.Users.Values | Where-Object UserPrincipalName -eq 'breakglass01@northwind.example').AccountEnabled | Should -BeTrue
            @($script:T.Calls | Where-Object { $_ -like '*breakglass01*' }).Count | Should -Be 0

            $script:Passwords.Count | Should -Be 3
        }

        It 'never writes a one-time password to the audit log or the summary file' {
            $script:Passwords = [System.Collections.Generic.List[string]]::new()
            $handler = { param($upn, $secure) $script:Passwords.Add([System.Net.NetworkCredential]::new('', $secure).Password) }
            $r = Invoke-JmlBatch -Path $script:SamplePath @script:Common -Execute -CredentialHandler $handler
            $script:Passwords.Count | Should -BeGreaterThan 0
            $audit = Get-Content -LiteralPath $script:P.Audit -Raw
            $summary = Get-Content -LiteralPath $r.SummaryPath -Raw
            foreach ($p in $script:Passwords) {
                $audit.Contains($p) | Should -BeFalse
                $summary.Contains($p) | Should -BeFalse
            }
        }

        It 'writes a summary file and one leaver checklist per due leaver' {
            $r = Invoke-JmlBatch -Path $script:SamplePath @script:Common -Execute
            $summary = Get-Content -LiteralPath $r.SummaryPath -Raw | ConvertFrom-Json
            $summary.mode | Should -Be 'Execute'
            $summary.sourceFile | Should -Be 'events.sample.csv'
            $summary.events.Count | Should -Be 10
            @(Get-ChildItem -LiteralPath $script:P.Output -Filter 'leaver-checklist-*.md').Count | Should -Be 2
        }

        It 'refuses a row without an approval reference and still processes the others' {
            Write-TestCsv $script:Csv @(
                'Leaver,2026-12-01,,,jamie.okafor@northwind.example,,,,,,,,',
                'Leaver,2026-12-01,HR-4002,,casey.nguyen@northwind.example,,,,,,,,yes')
            $r = Invoke-JmlBatch -Path $script:Csv @script:Common -Execute
            ($r.Results | Where-Object Row -eq 2).Status | Should -Be 'Refused'
            ($r.Results | Where-Object Row -eq 3).Status | Should -Be 'Succeeded'
            ($script:T.Users.Values | Where-Object UserPrincipalName -eq 'jamie.okafor@northwind.example').AccountEnabled | Should -BeTrue
        }

        It 'does not need an approval reference for a dry run' {
            Write-TestCsv $script:Csv @('Leaver,2026-12-01,,,jamie.okafor@northwind.example,,,,,,,,')
            (Invoke-JmlBatch -Path $script:Csv @script:Common).Results[0].Status | Should -Be 'WhatIf'
        }

        It 'refuses the whole file before any change when a limit is exceeded' {
            $custom = Join-Path $script:P.Root 'config'
            Copy-Item -LiteralPath $script:ConfigPath -Destination $custom -Recurse
            $f = Join-Path $custom 'settings.json'
            (Get-Content -LiteralPath $f -Raw).Replace('"maxLeaversPerRun": 5', '"maxLeaversPerRun": 1') | Set-Content -LiteralPath $f -Encoding utf8
            $a = $script:Common.Clone(); $a.ConfigPath = $custom
            { Invoke-JmlBatch -Path $script:SamplePath @a -Execute } | Should -Throw '*maxLeaversPerRun=1*'
            $script:T.Calls.Count | Should -Be 0
        }

        It 'is safe to run twice: the second run changes nothing new' {
            $null = Invoke-JmlBatch -Path $script:SamplePath @script:Common -Execute
            $calls = @($script:T.Calls | Where-Object { $_ -notlike 'Revoke-MgUserSignInSession*' }).Count
            $second = Invoke-JmlBatch -Path $script:SamplePath @script:Common -Execute
            @($script:T.Calls | Where-Object { $_ -notlike 'Revoke-MgUserSignInSession*' }).Count | Should -Be $calls
            @($second.Results | Where-Object { $_.EventType -eq 'Joiner' -and $_.Status -eq 'Succeeded' }).Count | Should -Be 0
            @($script:T.Users.Values | Where-Object UserPrincipalName -like 'priya.nair*').Count | Should -Be 1
        }
    }

    Context 'validation and scheduling' {
        It 'reports an invalid row on its own and carries on with the rest' {
            Write-TestCsv $script:Csv @(
                'Retire,2026-12-01,HR-1,,,,,,,,,,',
                'Mover,2026-12-01,HR-2,,taylor.reid@northwind.example,,,,,,,,',
                'Leaver,01/12/2026,HR-3,,jamie.okafor@northwind.example,,,,,,,,',
                'Leaver,2026-12-01,HR-4,,jamie.okafor@northwind.example,,,,,,,,')
            $r = Invoke-JmlBatch -Path $script:Csv @script:Common
            ($r.Results | Where-Object Row -eq 2).Detail | Should -Match 'must be Joiner, Mover or Leaver'
            ($r.Results | Where-Object Row -eq 3).Detail | Should -Match 'at least one of Department'
            ($r.Results | Where-Object Row -eq 4).Detail | Should -Match 'yyyy-MM-dd'
            ($r.Results | Where-Object Row -eq 5).Status | Should -Be 'WhatIf'
        }

        It 'stops at the first problem with -StopOnError' {
            Write-TestCsv $script:Csv @(
                'Retire,2026-12-01,HR-1,,,,,,,,,,',
                'Leaver,2026-12-01,HR-4,,jamie.okafor@northwind.example,,,,,,,,')
            $r = Invoke-JmlBatch -Path $script:Csv @script:Common -StopOnError
            ($r.Results | Where-Object Row -eq 3).Status | Should -Be 'NotProcessed'
        }

        It 'prepares joiners three days early and defers anything dated later' {
            Write-TestCsv $script:Csv @(
                'Joiner,2026-12-04,HR-1,NW3001,,Ana,Silva,Finance,Finance Analyst,sam.rivera@northwind.example,GB,,',
                'Joiner,2026-12-05,HR-2,NW3002,,Ben,Silva,Finance,Finance Analyst,sam.rivera@northwind.example,GB,,',
                'Leaver,2026-12-02,HR-3,,jamie.okafor@northwind.example,,,,,,,,')
            $r = Invoke-JmlBatch -Path $script:Csv @script:Common
            ($r.Results | Where-Object Row -eq 2).Status | Should -Be 'WhatIf'
            ($r.Results | Where-Object Row -eq 3).Status | Should -Be 'Deferred'
            ($r.Results | Where-Object Row -eq 4).Status | Should -Be 'Deferred'
        }

        It 'accepts any letter case for the event type and column names' {
            $lower = $script:Header.ToLowerInvariant()
            Set-Content -LiteralPath $script:Csv -Value @($lower, 'leaver,2026-12-01,HR-4,,jamie.okafor@northwind.example,,,,,,,,') -Encoding utf8
            (Invoke-JmlBatch -Path $script:Csv @script:Common).Results[0].Status | Should -Be 'WhatIf'
        }

        It 'throws for a missing file and for a file with no rows' {
            { Invoke-JmlBatch -Path (Join-Path $script:P.Root 'nope.csv') @script:Common } | Should -Throw '*not found*'
            Set-Content -LiteralPath $script:Csv -Value $script:Header -Encoding utf8
            { Invoke-JmlBatch -Path $script:Csv @script:Common } | Should -Throw '*no rows*'
        }
    }

    Context 'sample files' {
        It 'parses every sample file without a validation problem, apart from the deliberate one' {
            foreach ($name in 'joiners', 'movers', 'leavers') {
                $r = Invoke-JmlBatch -Path (Join-Path $script:RepoRoot "samples/$name.sample.csv") @script:Common
                @($r.Results | Where-Object Status -eq 'Invalid').Count | Should -Be 0
            }
            $all = Invoke-JmlBatch -Path $script:SamplePath @script:Common
            @($all.Results | Where-Object Status -eq 'Invalid').Count | Should -Be 1
        }
    }
}
