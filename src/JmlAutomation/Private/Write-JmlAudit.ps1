function Get-JmlActor {
    <#
    .SYNOPSIS
        Identifies who is running the automation, for the audit trail.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $context = Get-MgContext -ErrorAction Stop
        if ($context) {
            $account = Get-JmlProperty $context 'Account' $null
            if ($account) { return [string]$account }
            $appName = Get-JmlProperty $context 'AppName' $null
            if ($appName) { return "app:$appName" }
        }
    }
    catch { Write-Verbose 'No Graph context available for actor lookup.' }
    "os:$([Environment]::UserName)"
}

function Protect-JmlLogValue {
    <#
    .SYNOPSIS
        Removes secret-looking keys and values from audit detail before it is written.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()]$Value, [string]$Key = '')

    # Plain yes/no flags about password handling are useful audit facts and hold no secret.
    if ($Key -in 'passwordGenerated', 'forceChangePasswordNextSignIn' -and $Value -is [bool]) { return $Value }
    if ($Key -match '(?i)pass(word|phrase)?|secret|token|credential|pwd|apikey|api_key') { return '[redacted]' }
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Security.SecureString]) { return '[redacted]' }
    if ($Value -is [System.Collections.IDictionary]) {
        $clean = [ordered]@{}
        foreach ($k in $Value.Keys) { $clean["$k"] = Protect-JmlLogValue -Value $Value[$k] -Key "$k" }
        return $clean
    }
    if ($Value -is [string]) {
        $text = $Value -replace '(?i)(pass(word|phrase)?|secret|token|pwd)\s*[:=]\s*\S+', '$1=[redacted]'
        if ($text.Length -gt 500) { $text = $text.Substring(0, 500) + '...' }
        return $text
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return @($Value | ForEach-Object { Protect-JmlLogValue -Value $_ -Key $Key })
    }
    $Value
}

function Write-JmlAudit {
    <#
    .SYNOPSIS
        Appends one structured JSON line to the audit log.
    .DESCRIPTION
        The audit file is JSON Lines: one JSON object per line, UTC timestamps, no secrets.
        Writing the audit record is not a change to the tenant, so it still happens when the
        calling command runs under -WhatIf (the record is flagged with whatIf = true).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Actor,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Result,
        [bool]$DryRun = $false,
        [string]$ApprovalReference = '',
        [hashtable]$Detail = @{},
        [string]$ErrorMessage = ''
    )

    $record = [ordered]@{
        schemaVersion     = 1
        timestampUtc      = [DateTime]::UtcNow.ToString('o')
        runId             = $RunId
        actor             = $Actor
        host              = [Environment]::MachineName
        moduleVersion     = $script:JmlModuleVersion
        operation         = $Operation
        target            = $Target
        action            = $Action
        result            = $Result
        whatIf            = $DryRun
        approvalReference = $ApprovalReference
        detail            = Protect-JmlLogValue -Value $Detail
        error             = (Protect-JmlLogValue -Value $ErrorMessage)
    }
    $line = $record | ConvertTo-Json -Compress -Depth 6

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force -WhatIf:$false -Confirm:$false
    }
    [System.IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Resolve-JmlAuditPath {
    <#
    .SYNOPSIS
        Chooses the audit log file: explicit path, then settings folder, one file per UTC day.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Config, [string]$AuditLogPath)

    if ($AuditLogPath) { return $AuditLogPath }
    if ($env:JML_LOG_PATH) { return $env:JML_LOG_PATH }
    $directory = [string](Get-JmlSetting -Config $Config -Name 'audit.directory')
    if (-not [System.IO.Path]::IsPathRooted($directory)) { $directory = Join-Path (Get-Location).ProviderPath $directory }
    Join-Path $directory ("jml-audit-{0}.jsonl" -f [DateTime]::UtcNow.ToString('yyyyMMdd'))
}
