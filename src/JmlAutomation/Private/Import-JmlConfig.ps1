function Import-JmlConfig {
    <#
    .SYNOPSIS
        Loads and validates the JSON configuration from the config folder.
    .DESCRIPTION
        Resolution order for the folder: -Path, then the JML_CONFIG_PATH environment variable,
        then the config folder shipped next to the module. Validation errors are collected and
        thrown together so that an administrator can fix everything in one pass.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Path)

    if (-not $Path) {
        $Path = if ($env:JML_CONFIG_PATH) { $env:JML_CONFIG_PATH } else { $script:JmlDefaultConfigPath }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Configuration folder not found: $Path"
    }

    $read = {
        param([string]$FileName)
        $file = Join-Path $Path $FileName
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Configuration file missing: $file" }
        try { Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json -Depth 10 }
        catch { throw "Configuration file is not valid JSON: $file ($($_.Exception.Message))" }
    }

    $config = [pscustomobject]@{
        PSTypeName = 'Jml.Config'
        Path       = (Resolve-Path -LiteralPath $Path).ProviderPath
        Mapping    = & $read 'department-groups.json'
        Naming     = & $read 'naming.json'
        Licences   = & $read 'licences.json'
        Protected  = & $read 'protected-accounts.json'
        Settings   = & $read 'settings.json'
    }

    $problems = Test-JmlConfig -Config $config
    if ($problems.Count -gt 0) {
        throw ("Configuration is invalid:`n - " + ($problems -join "`n - "))
    }
    $config
}

function Test-JmlConfig {
    <#
    .SYNOPSIS
        Returns a list of validation problems for a loaded configuration (empty when valid).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)]$Config)

    $problems = [System.Collections.Generic.List[string]]::new()
    $knownTokens = '{given}', '{surname}', '{givenInitial}', '{employeeId}'

    # Group mapping
    $departments = @(Get-JmlProperty $Config.Mapping 'departments' @())
    if ($departments.Count -eq 0) { $problems.Add('department-groups.json: "departments" must contain at least one department.') }
    $seen = @{}
    foreach ($department in $departments) {
        $name = [string](Get-JmlProperty $department 'name' '')
        if (-not $name) { $problems.Add('department-groups.json: every department needs a "name".'); continue }
        if ($seen.ContainsKey($name.ToLowerInvariant())) { $problems.Add("department-groups.json: duplicate department '$name'.") }
        $seen[$name.ToLowerInvariant()] = $true
        if ($null -eq (Get-JmlProperty $department 'groups' $null)) { $problems.Add("department-groups.json: department '$name' needs a 'groups' array.") }
    }

    # Naming
    $domain = [string](Get-JmlProperty $Config.Naming 'domain' '')
    if ($domain -notmatch '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$') {
        $problems.Add('naming.json: "domain" must be a lower-case DNS name such as northwind.example.')
    }
    foreach ($key in 'userPrincipalNameFormat', 'mailNicknameFormat', 'displayNameFormat') {
        $format = [string](Get-JmlProperty $Config.Naming $key '')
        if (-not $format) { $problems.Add("naming.json: '$key' is required."); continue }
        foreach ($match in [regex]::Matches($format, '\{[^}]*\}')) {
            if ($match.Value -notin $knownTokens) { $problems.Add("naming.json: unknown token $($match.Value) in '$key'.") }
        }
    }

    # Licences
    $licenceGroups = @(Get-JmlProperty $Config.Licences 'licenceGroups' @())
    $default = [string](Get-JmlProperty $Config.Licences 'defaultLicenceGroup' '')
    if (-not $default) { $problems.Add('licences.json: "defaultLicenceGroup" is required.') }
    elseif ($default -notin $licenceGroups) { $problems.Add("licences.json: defaultLicenceGroup '$default' is not listed in licenceGroups.") }
    foreach ($override in @(Get-JmlProperty $Config.Licences 'departmentOverrides' @())) {
        $overrideGroup = [string](Get-JmlProperty $override 'licenceGroup' '')
        $overrideDepartment = [string](Get-JmlProperty $override 'department' '')
        if ($overrideGroup -notin $licenceGroups) { $problems.Add("licences.json: override group '$overrideGroup' is not listed in licenceGroups.") }
        if (-not $seen.ContainsKey($overrideDepartment.ToLowerInvariant())) { $problems.Add("licences.json: override department '$overrideDepartment' does not exist in department-groups.json.") }
    }

    # Settings
    $removal = [string](Get-JmlSetting -Config $Config -Name 'leaver.groupRemoval')
    if ($removal -notin 'All', 'ManagedOnly') { $problems.Add('settings.json: leaver.groupRemoval must be "All" or "ManagedOnly".') }
    foreach ($numeric in 'joiner.leadDays', 'joiner.passwordLength', 'batch.maxEventsPerRun', 'batch.maxLeaversPerRun') {
        $value = Get-JmlSetting -Config $Config -Name $numeric
        if ($value -isnot [int] -and $value -isnot [long]) { $problems.Add("settings.json: $numeric must be a whole number."); continue }
        if ($numeric -eq 'joiner.passwordLength' -and ($value -lt 16 -or $value -gt 64)) { $problems.Add('settings.json: joiner.passwordLength must be between 16 and 64.') }
        if ($numeric -ne 'joiner.passwordLength' -and $value -lt 0) { $problems.Add("settings.json: $numeric cannot be negative.") }
    }

    , $problems.ToArray()
}

function Get-JmlSetting {
    <#
    .SYNOPSIS
        Reads a dotted setting name (for example leaver.groupRemoval) with a built-in default.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Name
    )

    $defaults = @{
        'joiner.leadDays'                                  = 3
        'joiner.passwordLength'                            = 20
        'leaver.groupRemoval'                              = 'All'
        'leaver.resetMfaMethods'                           = $true
        'leaver.requireMailboxConversionBeforeLicenceRemoval' = $true
        'batch.maxEventsPerRun'                            = 25
        'batch.maxLeaversPerRun'                           = 5
        'batch.requireApprovalReference'                   = $true
        'audit.directory'                                  = './logs'
        'output.directory'                                 = './output'
    }

    $node = $Config.Settings
    foreach ($part in $Name.Split('.')) {
        $node = Get-JmlProperty $node $part $null
        if ($null -eq $node) { return $defaults[$Name] }
    }
    $node
}

function Get-JmlDepartmentEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Department)
    @(Get-JmlProperty $Config.Mapping 'departments' @()) |
        Where-Object { [string](Get-JmlProperty $_ 'name' '') -ieq $Department.Trim() } |
        Select-Object -First 1
}

function Get-JmlDesiredGroup {
    <#
    .SYNOPSIS
        Returns the groups a person should hold for a department and job title.
    .OUTPUTS
        Object with Groups (baseline, department and role groups), LicenceGroup and All.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Department,
        [AllowEmptyString()][string]$JobTitle = ''
    )

    $entry = Get-JmlDepartmentEntry -Config $Config -Department $Department
    if (-not $entry) { throw "Department '$Department' is not mapped in department-groups.json." }

    $groups = [System.Collections.Generic.List[string]]::new()
    foreach ($g in @(Get-JmlProperty $Config.Mapping 'baselineGroups' @())) { $groups.Add([string]$g) }
    foreach ($g in @(Get-JmlProperty $entry 'groups' @())) { $groups.Add([string]$g) }
    foreach ($role in @(Get-JmlProperty $entry 'roles' @())) {
        $pattern = [string](Get-JmlProperty $role 'titlePattern' '')
        if ($pattern -and $JobTitle -like $pattern) {
            foreach ($g in @(Get-JmlProperty $role 'groups' @())) { $groups.Add([string]$g) }
        }
    }

    $licenceGroup = [string](Get-JmlProperty $Config.Licences 'defaultLicenceGroup' '')
    foreach ($override in @(Get-JmlProperty $Config.Licences 'departmentOverrides' @())) {
        if ([string](Get-JmlProperty $override 'department' '') -ieq $entry.name) {
            $licenceGroup = [string](Get-JmlProperty $override 'licenceGroup' $licenceGroup)
        }
    }

    $unique = @($groups | Select-Object -Unique)
    [pscustomobject]@{
        Groups       = $unique
        LicenceGroup = $licenceGroup
        All          = @($unique + $licenceGroup | Select-Object -Unique)
    }
}

function Get-JmlManagedGroupName {
    <#
    .SYNOPSIS
        Returns every group name the automation is allowed to add or remove for Mover events.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)]$Config)

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($g in @(Get-JmlProperty $Config.Mapping 'baselineGroups' @())) { $names.Add([string]$g) }
    foreach ($department in @(Get-JmlProperty $Config.Mapping 'departments' @())) {
        foreach ($g in @(Get-JmlProperty $department 'groups' @())) { $names.Add([string]$g) }
        foreach ($role in @(Get-JmlProperty $department 'roles' @())) {
            foreach ($g in @(Get-JmlProperty $role 'groups' @())) { $names.Add([string]$g) }
        }
    }
    foreach ($g in @(Get-JmlProperty $Config.Licences 'licenceGroups' @())) { $names.Add([string]$g) }
    , @($names | Select-Object -Unique)
}
