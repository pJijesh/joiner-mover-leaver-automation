function New-JmlContext {
    <#
    .SYNOPSIS
        Creates the per-event context that carries identifiers, the audit path and the action list.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object only.')]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [Parameter(Mandatory)][string]$AuditLogPath,
        [bool]$DryRun = $false,
        [string]$ApprovalReference = '',
        [string]$RunId = ''
    )

    [pscustomobject]@{
        PSTypeName        = 'Jml.Context'
        Operation         = $Operation
        Target            = $Target
        Cmdlet            = $Cmdlet
        AuditLogPath      = $AuditLogPath
        DryRun            = $DryRun
        ApprovalReference = $ApprovalReference
        RunId             = $(if ($RunId) { $RunId } else { [guid]::NewGuid().ToString() })
        Actor             = Get-JmlActor
        Actions           = [System.Collections.Generic.List[object]]::new()
    }
}

function Add-JmlRecord {
    <#
    .SYNOPSIS
        Records one action outcome in memory and in the audit log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][ValidateSet('Succeeded', 'Failed', 'WhatIf', 'NoChange', 'Skipped', 'Refused', 'Declined')][string]$Result,
        [string]$Target,
        [hashtable]$Detail = @{},
        [string]$ErrorMessage = ''
    )

    $effectiveTarget = if ($Target) { $Target } else { $Context.Target }
    $entry = [pscustomobject]@{
        PSTypeName = 'Jml.Action'
        Action     = $Action
        Target     = $effectiveTarget
        Result     = $Result
        Detail     = $Detail
        Error      = $ErrorMessage
    }
    $Context.Actions.Add($entry)

    try {
        Write-JmlAudit -Path $Context.AuditLogPath -RunId $Context.RunId -Actor $Context.Actor `
            -Operation $Context.Operation -Target $effectiveTarget -Action $Action -Result $Result `
            -DryRun $Context.DryRun -ApprovalReference $Context.ApprovalReference -Detail $Detail -ErrorMessage $ErrorMessage
    }
    catch {
        # A broken audit trail must stop live changes: refuse to continue silently.
        throw "Audit log could not be written to '$($Context.AuditLogPath)': $($_.Exception.Message)"
    }
    $entry
}

function Format-JmlError {
    <#
    .SYNOPSIS
        Produces a single-line, length-limited error message that is safe to log.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$ErrorRecord)

    $message = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
    $message = ($message -replace '\s+', ' ').Trim()
    Protect-JmlLogValue -Value $message
}

function Invoke-JmlStep {
    <#
    .SYNOPSIS
        Runs one change under ShouldProcess, records the outcome and never lets a failure escape.
    .DESCRIPTION
        The script block is only invoked when the caller has not asked for -WhatIf and has
        confirmed. Any terminating or non-terminating error becomes a Failed record so the
        calling command can decide whether to continue.
    .OUTPUTS
        The action record (Result is Succeeded, Failed, WhatIf or Declined).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess is delegated to the calling public command through the context object.')]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][scriptblock]$Script,
        [string]$Target,
        [hashtable]$Detail = @{},
        [string]$TolerateErrorPattern = '',
        [string]$TolerateReason = ''
    )

    $effectiveTarget = if ($Target) { $Target } else { $Context.Target }

    if (-not $Context.Cmdlet.ShouldProcess($effectiveTarget, $Action)) {
        $outcome = if ($Context.DryRun) { 'WhatIf' } else { 'Declined' }
        return Add-JmlRecord -Context $Context -Action $Action -Result $outcome -Target $effectiveTarget -Detail $Detail
    }

    $ErrorActionPreference = 'Stop'
    try {
        $null = & $Script
        Add-JmlRecord -Context $Context -Action $Action -Result 'Succeeded' -Target $effectiveTarget -Detail $Detail
    }
    catch {
        $message = Format-JmlError -ErrorRecord $_
        if ($TolerateErrorPattern -and $message -match $TolerateErrorPattern) {
            $skipDetail = $Detail.Clone()
            $skipDetail.reason = $TolerateReason
            Add-JmlRecord -Context $Context -Action $Action -Result 'Skipped' -Target $effectiveTarget -Detail $skipDetail
        }
        else {
            Add-JmlRecord -Context $Context -Action $Action -Result 'Failed' -Target $effectiveTarget -Detail $Detail -ErrorMessage $message
        }
    }
}

function Invoke-JmlRetry {
    <#
    .SYNOPSIS
        Retries a Graph call that fails because a newly created object has not replicated yet or the service is throttling.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Script,
        [int]$MaxAttempts = 4,
        [int]$InitialDelaySeconds = 2
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try { return & $Script }
        catch {
            $text = $_.Exception.Message
            $transient = $text -match '(?i)Request_ResourceNotFound|ResourceNotFound|NotFound|404|429|TooManyRequests|ServiceUnavailable|503|Timeout|temporar'
            if (-not $transient -or $attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Seconds ($InitialDelaySeconds * [math]::Pow(2, $attempt - 1))
        }
    }
}

function New-JmlResult {
    <#
    .SYNOPSIS
        Builds the object returned to the caller from the recorded actions.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory object only.')]
    param(
        [Parameter(Mandatory)]$Context,
        [string]$Status,
        [string]$UserPrincipalName = '',
        [hashtable]$Extra = @{}
    )

    $actions = @($Context.Actions)
    if (-not $Status) {
        # The bookkeeping records (Start, Complete) say nothing about whether anything changed.
        $work = @($actions | Where-Object { $_.Action -notin 'Start', 'Complete' })
        $failed = @($work | Where-Object Result -eq 'Failed').Count
        $succeeded = @($work | Where-Object Result -eq 'Succeeded').Count
        $Status = if ($failed -gt 0 -and $succeeded -gt 0) { 'PartiallySucceeded' }
        elseif ($failed -gt 0) { 'Failed' }
        elseif ($Context.DryRun) { 'WhatIf' }
        elseif ($succeeded -gt 0) { 'Succeeded' }
        else { 'NoChange' }
    }

    $null = Add-JmlRecord -Context $Context -Action 'Complete' -Result $(if ($Status -in 'Failed', 'PartiallySucceeded') { 'Failed' } elseif ($Status -eq 'Refused') { 'Refused' } elseif ($Status -eq 'WhatIf') { 'WhatIf' } elseif ($Status -eq 'NoChange') { 'NoChange' } else { 'Succeeded' }) `
        -Detail @{ status = $Status; actionCount = $actions.Count }

    $result = [ordered]@{
        PSTypeName        = 'Jml.Result'
        Operation         = $Context.Operation
        UserPrincipalName = $(if ($UserPrincipalName) { $UserPrincipalName } else { $Context.Target })
        Status            = $Status
        WhatIf            = $Context.DryRun
        RunId             = $Context.RunId
        ApprovalReference = $Context.ApprovalReference
        FailedCount       = @($actions | Where-Object Result -eq 'Failed').Count
        Actions           = $actions
    }
    foreach ($key in $Extra.Keys) { $result[$key] = $Extra[$key] }
    [pscustomobject]$result
}
