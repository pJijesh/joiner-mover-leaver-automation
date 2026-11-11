BeforeAll {
    . (Join-Path $PSScriptRoot 'Common.ps1')

    # Copies the shipped configuration to a temp folder and lets a test edit one JSON file.
    function script:New-TestConfig {
        param([string]$Root, [string]$File, [scriptblock]$Edit)
        $folder = Join-Path $Root ('config-' + [guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:ConfigPath -Destination $folder -Recurse
        if ($File) {
            $path = Join-Path $folder $File
            $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 10
            & $Edit $json
            $json | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
        }
        $folder
    }
}

Describe 'Configuration' {
    BeforeEach { $script:P = New-TestPaths }
    AfterEach { Remove-Item -LiteralPath $script:P.Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'loads and validates the shipped configuration' {
        $config = InModuleScope JmlAutomation -Parameters @{ Path = $script:ConfigPath } { param($Path) Import-JmlConfig -Path $Path }
        $config.Naming.domain | Should -Be 'northwind.example'
        @($config.Mapping.departments).Count | Should -BeGreaterThan 3
    }

    It 'reports every problem in one message so an administrator can fix them together' {
        $folder = New-TestConfig -Root $script:P.Root -File 'naming.json' -Edit { param($j) $j.domain = 'Not A Domain'; $j.userPrincipalNameFormat = '{given}.{nickname}' }
        $settings = Join-Path $folder 'settings.json'
        (Get-Content -LiteralPath $settings -Raw).Replace('"groupRemoval": "All"', '"groupRemoval": "Everything"').Replace('"passwordLength": 20', '"passwordLength": 8') | Set-Content -LiteralPath $settings -Encoding utf8
        $message = try { InModuleScope JmlAutomation -Parameters @{ Path = $folder } { param($Path) Import-JmlConfig -Path $Path }; '' } catch { $_.Exception.Message }
        $message | Should -Match 'domain'
        $message | Should -Match 'unknown token \{nickname\}'
        $message | Should -Match 'groupRemoval'
        $message | Should -Match 'passwordLength'
    }

    It 'rejects a licence override that points at an unknown department or licence group' {
        $folder = New-TestConfig -Root $script:P.Root -File 'licences.json' -Edit { param($j) $j.departmentOverrides = @([pscustomobject]@{ department = 'Atlantis'; licenceGroup = 'NW-Lic-Nope' }) }
        $message = try { InModuleScope JmlAutomation -Parameters @{ Path = $folder } { param($Path) Import-JmlConfig -Path $Path }; '' } catch { $_.Exception.Message }
        $message | Should -Match "override department 'Atlantis'"
        $message | Should -Match "override group 'NW-Lic-Nope'"
    }

    It 'rejects a default licence group that is not in the licence list' {
        $folder = New-TestConfig -Root $script:P.Root -File 'licences.json' -Edit { param($j) $j.defaultLicenceGroup = 'NW-Lic-Missing' }
        { InModuleScope JmlAutomation -Parameters @{ Path = $folder } { param($Path) Import-JmlConfig -Path $Path } } | Should -Throw '*defaultLicenceGroup*'
    }

    It 'rejects invalid JSON and a missing file with a message that names the file' {
        $folder = New-TestConfig -Root $script:P.Root
        Set-Content -LiteralPath (Join-Path $folder 'naming.json') -Value '{ "domain": ' -Encoding utf8
        { InModuleScope JmlAutomation -Parameters @{ Path = $folder } { param($Path) Import-JmlConfig -Path $Path } } | Should -Throw '*not valid JSON*naming.json*'
        $folder = New-TestConfig -Root $script:P.Root
        Remove-Item -LiteralPath (Join-Path $folder 'protected-accounts.json')
        { InModuleScope JmlAutomation -Parameters @{ Path = $folder } { param($Path) Import-JmlConfig -Path $Path } } | Should -Throw '*protected-accounts.json*'
        { InModuleScope JmlAutomation { Import-JmlConfig -Path '/no/such/folder' } } | Should -Throw '*not found*'
    }

    It 'honours the JML_CONFIG_PATH environment variable when no path is given' {
        $folder = New-TestConfig -Root $script:P.Root -File 'naming.json' -Edit { param($j) $j.domain = 'contoso.example' }
        $old = $env:JML_CONFIG_PATH
        try {
            $env:JML_CONFIG_PATH = $folder
            (InModuleScope JmlAutomation { (Import-JmlConfig).Naming.domain }) | Should -Be 'contoso.example'
        }
        finally { $env:JML_CONFIG_PATH = $old }
    }

    It 'falls back to built-in defaults for settings that are left out, and respects false' {
        $folder = New-TestConfig -Root $script:P.Root -File 'settings.json' -Edit { param($j) $j.joiner = [pscustomobject]@{ leadDays = 5 }; $j.leaver = [pscustomobject]@{ resetMfaMethods = $false }; $j.PSObject.Properties.Remove('batch') }
        $values = InModuleScope JmlAutomation -Parameters @{ Path = $folder } {
            param($Path)
            $c = Import-JmlConfig -Path $Path
            @{ Lead = Get-JmlSetting -Config $c -Name 'joiner.leadDays'; Length = Get-JmlSetting -Config $c -Name 'joiner.passwordLength'
                Mfa = Get-JmlSetting -Config $c -Name 'leaver.resetMfaMethods'; Max = Get-JmlSetting -Config $c -Name 'batch.maxEventsPerRun'
                Approval = Get-JmlSetting -Config $c -Name 'batch.requireApprovalReference' }
        }
        $values.Lead | Should -Be 5
        $values.Length | Should -Be 20
        $values.Mfa | Should -BeFalse
        $values.Max | Should -Be 25
        $values.Approval | Should -BeTrue
    }

    It 'works out groups from department and job title, with the licence override' {
        $result = InModuleScope JmlAutomation -Parameters @{ Path = $script:ConfigPath } {
            param($Path)
            $c = Import-JmlConfig -Path $Path
            @{
                Finance = Get-JmlDesiredGroup -Config $c -Department 'finance' -JobTitle 'Senior Finance Manager'
                Warehouse = Get-JmlDesiredGroup -Config $c -Department 'Warehouse' -JobTitle 'Picker'
                Managed = Get-JmlManagedGroupName -Config $c
            }
        }
        $result.Finance.Groups | Should -Contain 'NW-Role-Finance-Approvers'
        $result.Finance.Groups | Should -Not -Contain 'NW-Role-Finance-Reporting'
        $result.Finance.LicenceGroup | Should -Be 'NW-Lic-Premium'
        $result.Warehouse.LicenceGroup | Should -Be 'NW-Lic-Frontline'
        $result.Warehouse.Groups.Count | Should -Be 4
        $result.Managed | Should -Contain 'NW-Lic-Standard'
        $result.Managed | Should -Not -Contain 'NW-Privileged-Admins'
    }

    It 'never maps a protected group, so the automation cannot add anyone to it' {
        InModuleScope JmlAutomation -Parameters @{ Path = $script:ConfigPath } {
            param($Path)
            $c = Import-JmlConfig -Path $Path
            $managed = Get-JmlManagedGroupName -Config $c
            foreach ($protected in $c.Protected.protectedGroupNames) { $managed | Should -Not -Contain $protected }
        }
    }
}

Describe 'Audit log' {
    BeforeEach { $script:P = New-TestPaths }
    AfterEach { Remove-Item -LiteralPath $script:P.Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'appends one JSON object per line with the documented fields and UTC timestamps' {
        InModuleScope JmlAutomation -Parameters @{ Path = $script:P.Audit } {
            param($Path)
            Write-JmlAudit -Path $Path -RunId 'run-1' -Actor 'it.admin@northwind.example' -Operation 'Joiner' -Target 'alex.morgan@northwind.example' -Action 'CreateUser' -Result 'Succeeded' -ApprovalReference 'HR-1' -Detail @{ department = 'Finance' }
            Write-JmlAudit -Path $Path -RunId 'run-1' -Actor 'it.admin@northwind.example' -Operation 'Joiner' -Target 'alex.morgan@northwind.example' -Action 'SetManager' -Result 'Failed' -ErrorMessage 'Request_ResourceNotFound'
        }
        $raw = @(Get-Content -LiteralPath $script:P.Audit)
        $raw.Count | Should -Be 2
        $first = $raw[0] | ConvertFrom-Json
        $first.schemaVersion | Should -Be 1
        $raw[0] | Should -MatchExactly '"timestampUtc":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z"'
        $first.runId | Should -Be 'run-1'
        $first.actor | Should -Be 'it.admin@northwind.example'
        $first.operation | Should -Be 'Joiner'
        $first.action | Should -Be 'CreateUser'
        $first.result | Should -Be 'Succeeded'
        $first.whatIf | Should -BeFalse
        $first.approvalReference | Should -Be 'HR-1'
        $first.detail.department | Should -Be 'Finance'
        ($raw[1] | ConvertFrom-Json).error | Should -Be 'Request_ResourceNotFound'
    }

    It 'redacts secret-looking keys and values, including nested ones' {
        $clean = InModuleScope JmlAutomation {
            Protect-JmlLogValue -Value @{
                password = 'P@ssw0rd!'; clientSecret = 'abc'; accessToken = 'eyJ'; nested = @{ apiKey = 'k'; ok = 'fine' }
                note = 'sign-in failed, password=Hunter2 supplied'; secure = ([System.Net.NetworkCredential]::new('', 'x').SecurePassword)
                list = @('token: abc123', 'plain')
            }
        }
        $json = $clean | ConvertTo-Json -Depth 6
        $json | Should -Not -Match 'P@ssw0rd'
        $json | Should -Not -Match 'Hunter2'
        $json | Should -Not -Match 'abc123'
        $json | Should -Not -Match 'eyJ'
        $clean['password'] | Should -Be '[redacted]'
        $clean['nested']['apiKey'] | Should -Be '[redacted]'
        $clean['nested']['ok'] | Should -Be 'fine'
        $clean['list'][1] | Should -Be 'plain'
    }

    It 'keeps the yes/no facts about password handling that the joiner records' {
        $clean = InModuleScope JmlAutomation { Protect-JmlLogValue -Value @{ passwordGenerated = $true; forceChangePasswordNextSignIn = $true; password = 'x' } }
        $clean['passwordGenerated'] | Should -BeTrue
        $clean['forceChangePasswordNextSignIn'] | Should -BeTrue
        $clean['password'] | Should -Be '[redacted]'
    }

    It 'shortens very long values so one bad error message cannot flood the log' {
        $clean = InModuleScope JmlAutomation { Protect-JmlLogValue -Value ('x' * 2000) }
        $clean.Length | Should -BeLessOrEqual 503
    }

    It 'creates the log folder when it does not exist' {
        $nested = Join-Path $script:P.Root 'a/b/audit.jsonl'
        InModuleScope JmlAutomation -Parameters @{ Path = $nested } { param($Path) Write-JmlAudit -Path $Path -RunId 'r' -Actor 'a' -Operation 'Joiner' -Target 't' -Action 'Start' -Result 'Succeeded' }
        Test-Path -LiteralPath $nested | Should -BeTrue
    }

    It 'names the log file by UTC day, honours JML_LOG_PATH, and lets an explicit path win' {
        $paths = InModuleScope JmlAutomation -Parameters @{ Path = $script:ConfigPath } {
            param($Path)
            $c = Import-JmlConfig -Path $Path
            $old = $env:JML_LOG_PATH
            try {
                $env:JML_LOG_PATH = $null
                $default = Resolve-JmlAuditPath -Config $c
                $env:JML_LOG_PATH = '/tmp/from-env.jsonl'
                @{ Default = $default; Env = (Resolve-JmlAuditPath -Config $c); Explicit = (Resolve-JmlAuditPath -Config $c -AuditLogPath '/tmp/explicit.jsonl') }
            }
            finally { $env:JML_LOG_PATH = $old }
        }
        $paths.Default | Should -Match 'jml-audit-\d{8}\.jsonl$'
        $paths.Env | Should -Be '/tmp/from-env.jsonl'
        $paths.Explicit | Should -Be '/tmp/explicit.jsonl'
    }

    It 'stops a live run before any change when the audit log cannot be written' {
        $T = New-FakeTenant; Initialize-StandardTenant $T; Register-FakeGraph
        $blocker = Join-Path $script:P.Root 'blocker'
        Set-Content -LiteralPath $blocker -Value 'a file, not a folder'
        $joiner = @{
            EmployeeId = 'NW1001'; GivenName = 'Alex'; Surname = 'Morgan'; Department = 'Finance'; JobTitle = 'Finance Analyst'
            ManagerUserPrincipalName = 'sam.rivera@northwind.example'; UsageLocation = 'GB'; ConfigPath = $script:ConfigPath
            AuditLogPath = (Join-Path $blocker 'audit.jsonl')
        }
        { New-JmlJoiner @joiner -Confirm:$false } | Should -Throw '*Audit log could not be written*'
        $T.Calls.Count | Should -Be 0
    }
}

Describe 'Naming, passwords and permissions helpers' {
    It 'turns names into safe user principal name tokens' -ForEach @(
        @{ Name = 'Zoë'; Expected = 'zoe' }
        @{ Name = "O'Neil"; Expected = 'oneil' }
        @{ Name = 'Mary Anne'; Expected = 'mary-anne' }
        @{ Name = 'Müller'; Expected = 'muller' }
        @{ Name = 'Łukasz'; Expected = 'lukasz' }
        @{ Name = 'Straße'; Expected = 'strasse' }
        @{ Name = '  Ng  '; Expected = 'ng' }
    ) {
        InModuleScope JmlAutomation -Parameters @{ Name = $Name } { param($Name) ConvertTo-JmlSlug -Name $Name } | Should -Be $Expected
    }

    It 'numbers colliding names and keeps the local part within the length limit' {
        $r = InModuleScope JmlAutomation -Parameters @{ Path = $script:ConfigPath } {
            param($Path)
            $c = Import-JmlConfig -Path $Path
            $c.Naming.maxLocalPartLength = 12
            @{
                First  = New-JmlIdentity -Config $c -GivenName 'Alex' -Surname 'Morgan'
                Second = New-JmlIdentity -Config $c -GivenName 'Alex' -Surname 'Morgan' -Sequence 2
                Long   = New-JmlIdentity -Config $c -GivenName 'Bartholomew' -Surname 'Featherstonehaugh' -Sequence 12
            }
        }
        $r.First.UserPrincipalName | Should -Be 'alex.morgan@northwind.example'
        $r.Second.UserPrincipalName | Should -Be 'alex.morgan2@northwind.example'
        $r.Second.DisplayName | Should -Be 'Alex Morgan'
        ($r.Long.UserPrincipalName.Split('@')[0]).Length | Should -BeLessOrEqual 12
        $r.Long.UserPrincipalName | Should -Match '12@northwind.example$'
    }

    It 'generates random passwords with every character class, no look-alikes, and no repeats' {
        $passwords = InModuleScope JmlAutomation {
            1..40 | ForEach-Object { ConvertFrom-JmlSecureString -SecureString (New-JmlPassword -Length 24) }
        }
        @($passwords | Select-Object -Unique).Count | Should -Be 40
        foreach ($p in $passwords) {
            $p.Length | Should -Be 24
            $p | Should -MatchExactly '[A-Z]'
            $p | Should -MatchExactly '[a-z]'
            $p | Should -MatchExactly '[0-9]'
            $p | Should -MatchExactly '[!@#$%^&*\-_=+?]'
            $p | Should -Not -MatchExactly '[01IOl]'
        }
    }

    It 'rejects a password length below 16' {
        { InModuleScope JmlAutomation { New-JmlPassword -Length 8 } } | Should -Throw
    }

    It 'asks for narrower permissions for a joiner than for a leaver, and the union for All' {
        $scopes = InModuleScope JmlAutomation {
            @{ Joiner = Get-JmlRequiredScope -Operation Joiner; Leaver = Get-JmlRequiredScope -Operation Leaver; All = Get-JmlRequiredScope -Operation All }
        }
        $scopes.Joiner | Should -Not -Contain 'UserAuthenticationMethod.ReadWrite.All'
        $scopes.Joiner | Should -Not -Contain 'LicenseAssignment.ReadWrite.All'
        $scopes.Leaver | Should -Contain 'UserAuthenticationMethod.ReadWrite.All'
        $scopes.Leaver | Should -Contain 'User.RevokeSessions.All'
        $scopes.All.Count | Should -Be (@($scopes.Joiner + $scopes.Leaver | Select-Object -Unique).Count)
        $scopes.All | Should -Not -Contain 'Directory.ReadWrite.All'
        $scopes.All | Should -Not -Contain 'RoleManagement.ReadWrite.Directory'
    }

    It 'accepts a broader permission that Microsoft documents as covering a narrower one' {
        $T = New-FakeTenant; Register-FakeGraph
        $T.Context.Scopes = @('User.ReadWrite.All', 'Group.ReadWrite.All')
        { InModuleScope JmlAutomation { Assert-JmlGraphContext -Operation Joiner } } | Should -Not -Throw
        $T.Context.Scopes = @('User.ReadWrite.All')
        { InModuleScope JmlAutomation { Assert-JmlGraphContext -Operation Joiner } } | Should -Throw '*GroupMember.ReadWrite.All*'
    }

    It 'warns instead of throwing for an app-only connection, where Graph reports roles not scopes' {
        $T = New-FakeTenant; Register-FakeGraph
        $T.Context.AuthType = 'AppOnly'; $T.Context.Scopes = @()
        $warning = InModuleScope JmlAutomation { Assert-JmlGraphContext -Operation Joiner 3>&1 | Out-String }
        $warning | Should -Match 'missing permissions'
    }

    It 'requests exactly the operation''s delegated scopes when connecting' {
        $null = New-FakeTenant; Register-FakeGraph
        Mock -ModuleName JmlAutomation Get-Module { [pscustomobject]@{ Name = 'Microsoft.Graph.Authentication' } } -ParameterFilter { $ListAvailable }
        Mock -ModuleName JmlAutomation Connect-MgGraph { }
        $null = Connect-JmlGraph -Operation Joiner -TenantId 'northwind.example'
        Should -Invoke -ModuleName JmlAutomation Connect-MgGraph -Times 1 -Exactly -ParameterFilter {
            $Scopes -contains 'User.ReadWrite.All' -and $Scopes -notcontains 'UserAuthenticationMethod.ReadWrite.All' -and $TenantId -eq 'northwind.example' -and $ContextScope -eq 'Process'
        }
    }

    It 'explains how to install the SDK when it is missing' {
        Mock -ModuleName JmlAutomation Get-Module { $null } -ParameterFilter { $ListAvailable }
        { Connect-JmlGraph -Operation Joiner } | Should -Throw '*Install-Module*'
    }
}

Describe 'Repository hygiene' {
    BeforeAll {
        $decode = { param($b64) [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) }
        # Terms that must never appear anywhere in this repository. Stored encoded so this file does not contain them.
        $script:Forbidden = @(
            @{ Pattern = [regex]::Escape((& $decode 'SW50ZXJuYXRpb25hbCBDYXJnbyBMb2dpc3RpY3M=')); Options = 'IgnoreCase' }
            @{ Pattern = [regex]::Escape((& $decode 'TWVudGZpZWxk')); Options = 'IgnoreCase' }
            @{ Pattern = [regex]::Escape((& $decode 'QXNjb20=')); Options = 'IgnoreCase' }
            @{ Pattern = [regex]::Escape((& $decode 'SGlCb2I=')); Options = 'IgnoreCase' }
            @{ Pattern = [regex]::Escape((& $decode 'VHJhbnMgRGF0YQ==')); Options = 'IgnoreCase' }
            @{ Pattern = [regex]::Escape((& $decode 'ZnJhY3Rpb25hbCBDVE8=')); Options = 'IgnoreCase' }
            @{ Pattern = [regex]::Escape((& $decode 'QW50aHJvcGlj')); Options = 'IgnoreCase' }
            @{ Pattern = [regex]::Escape((& $decode 'Q2xhdWRl')); Options = 'IgnoreCase' }
            @{ Pattern = '\b' + [regex]::Escape((& $decode 'SUNM')) + '\b'; Options = 'None' }
            @{ Pattern = '\b' + [regex]::Escape((& $decode 'VERN')) + '\b'; Options = 'None' }
            @{ Pattern = "[$([char]0x2013)$([char]0x2014)]"; Options = 'None' }
        )
        $skip = '[\\/](\.git|logs|output|node_modules)[\\/]'
        $script:Files = @(Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File -Force |
                Where-Object { $_.FullName -notmatch $skip -and $_.Extension -in '.ps1', '.psm1', '.psd1', '.json', '.md', '.csv', '.yml', '.yaml', '.mmd', '.txt', '.gitignore', '' -and $_.Length -lt 1MB })
    }

    It 'finds the files it is meant to scan' {
        $script:Files.Count | Should -BeGreaterThan 20
    }

    It 'contains no real organisation names, tool-maker names or long dashes' {
        $hits = foreach ($file in $script:Files) {
            $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
            if (-not $text) { continue }
            foreach ($term in $script:Forbidden) {
                if ([regex]::IsMatch($text, $term.Pattern, [System.Text.RegularExpressions.RegexOptions]$term.Options)) { "$($file.Name): forbidden term matched" }
            }
        }
        $hits | Should -BeNullOrEmpty
    }

    It 'uses only example domains for email addresses and user principal names' {
        $hits = foreach ($file in $script:Files) {
            $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
            if (-not $text) { continue }
            foreach ($m in [regex]::Matches($text, '[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,}')) {
                if ($m.Value -notmatch '\.example$' -and $m.Value -notmatch '^(noreply|p\.jijesh)@') { "$($file.Name): $($m.Value)" }
            }
        }
        $hits | Should -BeNullOrEmpty
    }

    It 'contains nothing that looks like a secret, a GUID tenant or a real certificate thumbprint' {
        $hits = foreach ($file in $script:Files | Where-Object { $_.Name -notin 'psd1' -and $_.Extension -ne '.psd1' }) {
            $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
            if (-not $text) { continue }
            if ($text -match '(?i)client_?secret\s*[:=]\s*[''"]?[A-Za-z0-9~._-]{20,}') { "$($file.Name): client secret" }
            if ($text -match '[A-Fa-f0-9]{40}(?![A-Fa-f0-9])') { "$($file.Name): 40-character hex string" }
            if ($text -match '(?i)tenant(id)?\s*[:=]\s*[''"]?[0-9a-f]{8}-[0-9a-f]{4}-') { "$($file.Name): tenant GUID" }
        }
        $hits | Should -BeNullOrEmpty
    }
}
