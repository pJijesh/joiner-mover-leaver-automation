function Get-JmlCsvValue {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)][string]$Name)
    $property = $Row.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if (-not $property -or $null -eq $property.Value) { return '' }
    ([string]$property.Value).Trim()
}

function ConvertTo-JmlBatchEvent {
    <#
    .SYNOPSIS
        Validates one CSV row and works out whether the event is due. Returns a hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][int]$RowNumber,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][datetime]$AsOfDate
    )

    $evt = @{
        Row               = $RowNumber
        EventType         = (Get-JmlCsvValue -Row $Row -Name 'EventType')
        EffectiveDate     = $null
        ApprovalReference = (Get-JmlCsvValue -Row $Row -Name 'ApprovalReference')
        EmployeeId        = (Get-JmlCsvValue -Row $Row -Name 'EmployeeId')
        UserPrincipalName = (Get-JmlCsvValue -Row $Row -Name 'UserPrincipalName')
        GivenName         = (Get-JmlCsvValue -Row $Row -Name 'GivenName')
        Surname           = (Get-JmlCsvValue -Row $Row -Name 'Surname')
        Department        = (Get-JmlCsvValue -Row $Row -Name 'Department')
        JobTitle          = (Get-JmlCsvValue -Row $Row -Name 'JobTitle')
        ManagerUpn        = (Get-JmlCsvValue -Row $Row -Name 'ManagerUpn')
        UsageLocation     = (Get-JmlCsvValue -Row $Row -Name 'UsageLocation')
        OfficeLocation    = (Get-JmlCsvValue -Row $Row -Name 'OfficeLocation')
        MailboxConverted  = ((Get-JmlCsvValue -Row $Row -Name 'MailboxConverted') -match '^(?i:true|yes|y|1)$')
        Problems          = [System.Collections.Generic.List[string]]::new()
        Due               = $false
        DueFrom           = $AsOfDate
        Target            = ''
    }

    $type = $evt.EventType
    $canonical = @('Joiner', 'Mover', 'Leaver') | Where-Object { $_ -ieq $type } | Select-Object -First 1
    if (-not $canonical) { $evt.Problems.Add("Row ${RowNumber}: EventType must be Joiner, Mover or Leaver."); return $evt }
    $evt.EventType = $canonical

    $dateText = Get-JmlCsvValue -Row $Row -Name 'EffectiveDate'
    if ($dateText) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($dateText, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) { $evt.EffectiveDate = $parsed }
        else { $evt.Problems.Add("Row ${RowNumber}: EffectiveDate must be yyyy-MM-dd.") }
    }

    switch ($canonical) {
        'Joiner' {
            foreach ($field in 'EmployeeId', 'GivenName', 'Surname', 'Department', 'JobTitle', 'ManagerUpn', 'UsageLocation') {
                if (-not $evt[$field]) { $evt.Problems.Add("Row ${RowNumber}: $field is required for a Joiner.") }
            }
            $evt.Target = "employee:$($evt.EmployeeId)"
            $lead = [int](Get-JmlSetting -Config $Config -Name 'joiner.leadDays')
            if ($evt.EffectiveDate) { $evt.DueFrom = $evt.EffectiveDate.AddDays(-$lead) }
        }
        'Mover' {
            if (-not $evt.UserPrincipalName) { $evt.Problems.Add("Row ${RowNumber}: UserPrincipalName is required for a Mover.") }
            if (-not ($evt.Department -or $evt.JobTitle -or $evt.ManagerUpn -or $evt.OfficeLocation)) {
                $evt.Problems.Add("Row ${RowNumber}: a Mover needs at least one of Department, JobTitle, ManagerUpn or OfficeLocation.")
            }
            $evt.Target = $evt.UserPrincipalName
            if ($evt.EffectiveDate) { $evt.DueFrom = $evt.EffectiveDate }
        }
        'Leaver' {
            if (-not $evt.UserPrincipalName) { $evt.Problems.Add("Row ${RowNumber}: UserPrincipalName is required for a Leaver.") }
            $evt.Target = $evt.UserPrincipalName
            if ($evt.EffectiveDate) { $evt.DueFrom = $evt.EffectiveDate }
        }
    }
    $evt.Due = ($evt.DueFrom -le $AsOfDate)
    $evt
}

function Write-JmlBatchAudit {
    <#
    .SYNOPSIS
        Writes an audit line for a batch row that never reached a worker command (invalid, deferred, refused).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)]$BatchEvent,
        [Parameter(Mandatory)][bool]$DryRun,
        [Parameter(Mandatory)][string]$Result,
        [string]$Detail = '',
        $Config
    )

    $target = if ($BatchEvent.Target) { $BatchEvent.Target } else { "row:$($BatchEvent.Row)" }
    $type = if ($BatchEvent.EventType) { $BatchEvent.EventType } else { 'Unknown' }
    $null = $Config
    Write-JmlAudit -Path $Path -RunId $RunId -Actor (Get-JmlActor) -Operation "Batch$type" -Target $target `
        -Action 'BatchRow' -Result $Result -DryRun $DryRun -ApprovalReference $BatchEvent.ApprovalReference `
        -Detail @{ row = $BatchEvent.Row; note = $Detail }
}
