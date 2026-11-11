function Invoke-JmlBatch {
    <#
    .SYNOPSIS
        Processes a CSV of joiner, mover and leaver events. Dry run unless -Execute is passed.
    .DESCRIPTION
        Safety rules:
          * Without -Execute every event runs under -WhatIf: nothing in the tenant changes.
          * With -Execute each row needs an ApprovalReference (configurable) and the run is
            stopped before it starts if the file exceeds the limits in settings.json.
          * Events dated in the future are deferred (joiners are prepared a few days early,
            see joiner.leadDays). Run the same file again on the due date.
          * Invalid rows fail on their own and do not stop the rest of the file.

        CSV columns: EventType (Joiner, Mover, Leaver), EffectiveDate (yyyy-MM-dd), ApprovalReference,
        EmployeeId, UserPrincipalName, GivenName, Surname, Department, JobTitle, ManagerUpn,
        UsageLocation, OfficeLocation, MailboxConverted. See samples/ for examples.

        A summary JSON file is written to the output folder. It never contains passwords.
    .PARAMETER Path
        CSV file to process.
    .PARAMETER Execute
        Apply the changes for real. Without it the run is a dry run.
    .PARAMETER AsOfDate
        Treat this as today (yyyy-MM-dd). Useful for rehearsals and tests.
    .PARAMETER CredentialHandler
        Passed to New-JmlJoiner so one-time passwords can go straight to a secure channel.
    .PARAMETER StopOnError
        Stop at the first failed event instead of carrying on.
    .EXAMPLE
        Invoke-JmlBatch -Path .\samples\events.sample.csv
    .EXAMPLE
        Invoke-JmlBatch -Path .\events.csv -Execute -CredentialHandler { param($upn, $secure) Send-ToVault $upn $secure }
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [switch]$Execute,
        [datetime]$AsOfDate = (Get-Date).Date,
        [scriptblock]$CredentialHandler,
        [switch]$StopOnError,
        [string]$ConfigPath,
        [string]$AuditLogPath,
        [string]$OutputPath
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "CSV file not found: $Path" }
    $config = Import-JmlConfig -Path $ConfigPath
    $rows = @(Import-Csv -LiteralPath $Path -Encoding utf8)
    if ($rows.Count -eq 0) { throw "CSV file has no rows: $Path" }

    $runId = [guid]::NewGuid().ToString()
    $auditPath = Resolve-JmlAuditPath -Config $config -AuditLogPath $AuditLogPath
    $outputDirectory = if ($OutputPath) { $OutputPath } else {
        $configured = [string](Get-JmlSetting -Config $config -Name 'output.directory')
        if ([System.IO.Path]::IsPathRooted($configured)) { $configured } else { Join-Path (Get-Location).ProviderPath $configured }
    }

    # Parse and validate every row first. Nothing is sent to Graph yet.
    $events = for ($i = 0; $i -lt $rows.Count; $i++) { ConvertTo-JmlBatchEvent -Row $rows[$i] -RowNumber ($i + 2) -Config $config -AsOfDate $AsOfDate }

    $due = @($events | Where-Object { $_.Problems.Count -eq 0 -and $_.Due })
    $limits = @(
        @{ Name = 'maxEventsPerRun'; Count = $due.Count; Limit = [int](Get-JmlSetting -Config $config -Name 'batch.maxEventsPerRun') }
        @{ Name = 'maxLeaversPerRun'; Count = @($due | Where-Object EventType -eq 'Leaver').Count; Limit = [int](Get-JmlSetting -Config $config -Name 'batch.maxLeaversPerRun') }
    )
    $breach = @($limits | Where-Object { $_.Limit -gt 0 -and $_.Count -gt $_.Limit })
    if ($breach.Count -gt 0 -and $Execute) {
        $text = ($breach | ForEach-Object { "$($_.Name)=$($_.Limit) (file has $($_.Count))" }) -join '; '
        throw "Batch refused before any change: limit exceeded: $text. Check the file, or raise the limit in settings.json after review."
    }

    $proceed = $false
    if ($Execute) { $proceed = $PSCmdlet.ShouldProcess($Path, "Apply $($due.Count) joiner, mover and leaver events to the tenant") }
    $dryRun = -not $proceed
    if ($dryRun) { Write-Information 'DRY RUN: no changes will be made. Pass -Execute to apply them.' -InformationAction Continue }
    else { Write-Warning "EXECUTE mode: $($due.Count) event(s) will change the tenant." }
    if ($breach.Count -gt 0) {
        foreach ($b in $breach) { Write-Warning "Dry run notice: $($b.Name) limit is $($b.Limit) and the file has $($b.Count). -Execute would be refused." }
    }

    $requireApproval = (Get-JmlSetting -Config $config -Name 'batch.requireApprovalReference') -eq $true
    $results = [System.Collections.Generic.List[object]]::new()
    $stopped = $false

    foreach ($evt in $events) {
        if ($stopped) {
            $results.Add([pscustomobject]@{ Row = $evt.Row; EventType = $evt.EventType; Target = $evt.Target; Status = 'NotProcessed'; Detail = 'Stopped after an earlier failure (-StopOnError).'; Result = $null })
            continue
        }
        if ($evt.Problems.Count -gt 0) {
            $results.Add([pscustomobject]@{ Row = $evt.Row; EventType = $evt.EventType; Target = $evt.Target; Status = 'Invalid'; Detail = ($evt.Problems -join ' '); Result = $null })
            Write-JmlBatchAudit -Path $auditPath -RunId $runId -BatchEvent $evt -DryRun $dryRun -Result 'Failed' -Detail ($evt.Problems -join ' ') -Config $config
            if ($StopOnError) { $stopped = $true }
            continue
        }
        if (-not $evt.Due) {
            $results.Add([pscustomobject]@{ Row = $evt.Row; EventType = $evt.EventType; Target = $evt.Target; Status = 'Deferred'; Detail = "Not due until $($evt.DueFrom.ToString('yyyy-MM-dd'))."; Result = $null })
            Write-JmlBatchAudit -Path $auditPath -RunId $runId -BatchEvent $evt -DryRun $dryRun -Result 'Skipped' -Detail "Deferred until $($evt.DueFrom.ToString('yyyy-MM-dd'))." -Config $config
            continue
        }
        if ($Execute -and $requireApproval -and -not $evt.ApprovalReference) {
            $results.Add([pscustomobject]@{ Row = $evt.Row; EventType = $evt.EventType; Target = $evt.Target; Status = 'Refused'; Detail = 'ApprovalReference is required to execute.'; Result = $null })
            Write-JmlBatchAudit -Path $auditPath -RunId $runId -BatchEvent $evt -DryRun $dryRun -Result 'Refused' -Detail 'ApprovalReference is required to execute.' -Config $config
            if ($StopOnError) { $stopped = $true }
            continue
        }

        $common = @{ WhatIf = $dryRun; ConfigPath = $config.Path; AuditLogPath = $auditPath; RunId = $runId; ApprovalReference = $evt.ApprovalReference }
        if (-not $dryRun) { $common.Confirm = $false }
        try {
            $result = switch ($evt.EventType) {
                'Joiner' {
                    $arguments = @{
                        EmployeeId = $evt.EmployeeId; GivenName = $evt.GivenName; Surname = $evt.Surname
                        Department = $evt.Department; JobTitle = $evt.JobTitle; ManagerUserPrincipalName = $evt.ManagerUpn
                        UsageLocation = $evt.UsageLocation
                    }
                    if ($evt.OfficeLocation) { $arguments.OfficeLocation = $evt.OfficeLocation }
                    if ($evt.EffectiveDate) { $arguments.StartDate = $evt.EffectiveDate }
                    if ($CredentialHandler) { $arguments.CredentialHandler = $CredentialHandler }
                    New-JmlJoiner @arguments @common
                }
                'Mover' {
                    $arguments = @{ UserPrincipalName = $evt.UserPrincipalName }
                    foreach ($name in 'Department', 'JobTitle', 'OfficeLocation') { if ($evt[$name]) { $arguments[$name] = $evt[$name] } }
                    if ($evt.ManagerUpn) { $arguments.ManagerUserPrincipalName = $evt.ManagerUpn }
                    Move-JmlUser @arguments @common
                }
                'Leaver' {
                    $arguments = @{ UserPrincipalName = $evt.UserPrincipalName; OutputPath = $outputDirectory }
                    if ($evt.EffectiveDate) { $arguments.LeaveDate = $evt.EffectiveDate }
                    if ($evt.MailboxConverted) { $arguments.MailboxConverted = $true }
                    Remove-JmlLeaver @arguments @common
                }
            }
            $results.Add([pscustomobject]@{ Row = $evt.Row; EventType = $evt.EventType; Target = $result.UserPrincipalName; Status = $result.Status; Detail = "$($result.FailedCount) failed action(s)"; Result = $result })
            if ($StopOnError -and $result.Status -in 'Failed', 'PartiallySucceeded') { $stopped = $true }
        }
        catch {
            $message = Format-JmlError -ErrorRecord $_
            $results.Add([pscustomobject]@{ Row = $evt.Row; EventType = $evt.EventType; Target = $evt.Target; Status = 'Failed'; Detail = $message; Result = $null })
            Write-JmlBatchAudit -Path $auditPath -RunId $runId -BatchEvent $evt -DryRun $dryRun -Result 'Failed' -Detail $message -Config $config
            if ($StopOnError) { $stopped = $true }
        }
    }

    # Summary file: no passwords, no secrets.
    $counts = [ordered]@{}
    foreach ($group in ($results | Group-Object Status | Sort-Object Name)) { $counts[$group.Name] = $group.Count }
    $summary = [ordered]@{
        runId        = $runId
        generatedUtc = [DateTime]::UtcNow.ToString('o')
        mode         = $(if ($dryRun) { 'DryRun' } else { 'Execute' })
        asOfDate     = $AsOfDate.ToString('yyyy-MM-dd')
        sourceFile   = (Split-Path -Path $Path -Leaf)
        counts       = $counts
        events       = @($results | ForEach-Object {
                [ordered]@{ row = $_.Row; eventType = $_.EventType; target = $_.Target; status = $_.Status; detail = (Protect-JmlLogValue -Value $_.Detail) }
            })
    }
    if (-not (Test-Path -LiteralPath $outputDirectory)) { $null = New-Item -ItemType Directory -Path $outputDirectory -Force -WhatIf:$false -Confirm:$false }
    $summaryPath = Join-Path $outputDirectory "batch-summary-$runId.json"
    [System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))

    [pscustomobject]@{
        PSTypeName  = 'Jml.BatchResult'
        RunId       = $runId
        Mode        = $summary.mode
        Counts      = [pscustomobject]$counts
        SummaryPath = $summaryPath
        AuditLog    = $auditPath
        Results     = $results.ToArray()
    }
}
