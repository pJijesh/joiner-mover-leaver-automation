function ConvertTo-JmlMarkdownCell {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()]$Value)
    if ($null -eq $Value) { return '' }
    $text = ($Value | Out-String).Trim()
    ($text -replace '\|', '/' -replace '\r?\n', ' ')
}

function Export-JmlLeaverChecklist {
    <#
    .SYNOPSIS
        Writes the leaver checklist (automated results, manual steps, manager handover notes) as Markdown.
    .DESCRIPTION
        The file is written even for a dry run, clearly marked as a preview, so IT and the manager
        can review it before the live run. It contains no secrets: names, group names and results only.
    .OUTPUTS
        The full path of the checklist file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][hashtable]$Snapshot
    )

    $upn = $Snapshot.UserPrincipalName
    $localPart = ($upn.Split('@')[0] -replace '[^A-Za-z0-9._-]', '_')
    $stamp = if ($Snapshot.LeaveDate) { ([datetime]$Snapshot.LeaveDate).ToString('yyyyMMdd') } else { [DateTime]::UtcNow.ToString('yyyyMMdd') }
    $fileName = "leaver-checklist-$localPart-$stamp.md"
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        $null = New-Item -ItemType Directory -Path $OutputDirectory -Force -WhatIf:$false -Confirm:$false
    }
    $path = Join-Path $OutputDirectory $fileName

    $mode = if ($Context.DryRun) { 'DRY RUN PREVIEW. Nothing has been changed in the tenant.' } else { 'LIVE RUN. Results below are what actually happened.' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# Leaver checklist: $($Snapshot.DisplayName)")
    $lines.Add('')
    $lines.Add("> $mode")
    $lines.Add('')
    $lines.Add('| Item | Value |')
    $lines.Add('|---|---|')
    $lines.Add("| Account | $(ConvertTo-JmlMarkdownCell $upn) |")
    $lines.Add("| Leave date | $(ConvertTo-JmlMarkdownCell $Snapshot.LeaveDateText) |")
    $lines.Add("| Line manager | $(ConvertTo-JmlMarkdownCell $Snapshot.ManagerText) |")
    $lines.Add("| Approval reference | $(ConvertTo-JmlMarkdownCell $Context.ApprovalReference) |")
    $lines.Add("| Run ID | $($Context.RunId) |")
    $lines.Add("| Generated (UTC) | $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm')) |")
    $lines.Add('')

    $lines.Add('## 1. Automated steps (Microsoft Graph)')
    $lines.Add('')
    $lines.Add('| Step | Target | Result | Note |')
    $lines.Add('|---|---|---|---|')
    foreach ($action in $Context.Actions) {
        if ($action.Action -in 'Start', 'Complete') { continue }
        $note = if ($action.Error) { $action.Error } elseif ($action.Detail -and $action.Detail.ContainsKey('reason')) { $action.Detail['reason'] } else { '' }
        $lines.Add("| $(ConvertTo-JmlMarkdownCell $action.Action) | $(ConvertTo-JmlMarkdownCell $action.Target) | $($action.Result) | $(ConvertTo-JmlMarkdownCell $note) |")
    }
    $lines.Add('')

    $lines.Add('## 2. Manual steps (not possible through Microsoft Graph)')
    $lines.Add('')
    $lines.Add('Tick each box and record the date and your initials. Do not close the ticket until every box is ticked or marked not applicable with a reason.')
    $lines.Add('')
    $lines.Add('### Mailbox (Exchange Online administrator)')
    if ($Snapshot.LicencesHeld) {
        $lines.Add('- [ ] **Convert the mailbox to a shared mailbox first.** In the Microsoft 365 admin centre: Users, Active users, select the person, Mail tab, Convert to shared mailbox. Exchange Online PowerShell equivalent: `Set-Mailbox -Identity <upn> -Type Shared`. The mailbox must still be licensed for the conversion option to appear.')
        $lines.Add('- [ ] Check the mailbox size. A shared mailbox without a licence is limited to 50 GB. A mailbox on litigation hold or in-place hold, or needing a larger archive, needs an Exchange Online Plan 2 licence (or Plan 1 plus Exchange Online Archiving).')
        $lines.Add('- [ ] **Then re-run this tool with `-MailboxConverted`** so group-based and direct licences are reclaimed. Licences have been held back on purpose in this run.')
    }
    else {
        $lines.Add('- [ ] Confirm the mailbox was converted to a shared mailbox before the licence was removed (Exchange Online PowerShell: `Get-Mailbox -Identity <upn> | Select RecipientTypeDetails`). If it was not, re-assign a licence, convert, then remove it again. An unlicensed user mailbox is deleted after a grace period.')
    }
    $lines.Add('- [ ] Grant the line manager (or nominated delegate) access to the shared mailbox if HR and the manager agree, and record who approved it.')
    $lines.Add('- [ ] Set an automatic reply and any forwarding only where company policy and the manager allow it. Forwarding to personal addresses is not permitted.')
    $lines.Add('- [ ] Remove the person from distribution lists and mail-enabled security groups. These cannot be changed through Graph and are listed in the skipped groups below.')
    $lines.Add('')
    $lines.Add('### OneDrive and files (SharePoint administrator)')
    $lines.Add('- [ ] Give the line manager access to the OneDrive now, while the account still exists (SharePoint admin centre or Microsoft 365 admin centre, Active users, OneDrive tab).')
    $lines.Add('- [ ] Decide the retention period. A deleted user''s OneDrive is kept for 30 days by default and the clock only starts when the account is deleted, not when it is disabled. Change the tenant setting first if the business needs longer.')
    $lines.Add('- [ ] Check for legal, compliance or eDiscovery holds before any deletion is scheduled.')
    $lines.Add('- [ ] Transfer ownership of Teams, Microsoft 365 groups, SharePoint sites and Power Platform items the person owns. Group ownership is separate from membership and is not changed by this tool.')
    $lines.Add('')
    $lines.Add('### Devices and physical assets (service desk)')
    $lines.Add('- [ ] Collect laptop, phone, tokens, badges and any other equipment. Record asset tags and the date received.')
    $lines.Add('- [ ] In Intune: retire or wipe the managed devices according to policy (corporate devices wiped, personal devices retired). Remove the device from Autopilot if it will be reused.')
    $lines.Add('- [ ] Record BitLocker or FileVault recovery key handling and confirm device sanitisation before reuse or disposal.')
    $lines.Add('- [ ] Remove building access, parking, corporate card and phone number assignments.')
    $lines.Add('')
    $lines.Add('### Applications and third-party accounts (application owners)')
    $lines.Add('- [ ] Applications using Entra single sign-on lose access once the account is disabled. Confirm this for each critical application.')
    $lines.Add('- [ ] Disable or transfer accounts in systems that do not use single sign-on (finance, CRM, code repositories, customer portals, supplier portals). Keep a list in the ticket.')
    $lines.Add('- [ ] Rotate any shared passwords, API keys, secrets or certificates the person knew or owned.')
    $lines.Add('- [ ] Review OAuth app consents and personal access tokens created by the person.')
    $lines.Add('')
    $lines.Add('### Hybrid identity and record keeping')
    $lines.Add('- [ ] If the account is synced from on-premises Active Directory, disable it in Active Directory. This tool refuses synced accounts.')
    $lines.Add('- [ ] HR confirms the leaver in the HR system and that final-day access removal matches the contractual leave date.')
    $lines.Add('- [ ] Schedule account deletion after the agreed retention period. Deleted Entra users stay in the recycle bin for 30 days before permanent deletion.')
    $lines.Add('- [ ] Attach this checklist and the audit log extract (run ID above) to the ticket and obtain the manager''s sign-off.')
    $lines.Add('')

    $lines.Add('## 3. Handover notes for the line manager')
    $lines.Add('')
    $lines.Add("Manager: $(ConvertTo-JmlMarkdownCell $Snapshot.ManagerText)")
    $lines.Add('')
    $lines.Add('**Direct reports needing a new manager in the HR system**')
    $lines.Add('')
    if ($Snapshot.DirectReports.Count -gt 0) { foreach ($report in $Snapshot.DirectReports) { $lines.Add("- $(ConvertTo-JmlMarkdownCell $report)") } }
    else { $lines.Add('- None recorded.') }
    $lines.Add('')
    $lines.Add('**Groups the person belonged to (access snapshot, useful for replacement hires)**')
    $lines.Add('')
    if ($Snapshot.GroupsBefore.Count -gt 0) { foreach ($g in $Snapshot.GroupsBefore) { $lines.Add("- $(ConvertTo-JmlMarkdownCell $g)") } }
    else { $lines.Add('- None recorded.') }
    $lines.Add('')
    $lines.Add('**Groups that need a manual decision (skipped by the automation)**')
    $lines.Add('')
    if ($Snapshot.GroupsSkipped.Count -gt 0) { foreach ($g in $Snapshot.GroupsSkipped) { $lines.Add("- $(ConvertTo-JmlMarkdownCell $g)") } }
    else { $lines.Add('- None.') }
    $lines.Add('')
    $lines.Add('**Authentication methods found**')
    $lines.Add('')
    $lines.Add("- $(ConvertTo-JmlMarkdownCell $Snapshot.MfaSummary)")
    $lines.Add('')

    [System.IO.File]::WriteAllText($path, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
    $path
}
