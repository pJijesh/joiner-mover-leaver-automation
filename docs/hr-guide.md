# HR guide

This page is for HR and people managers. It explains what the automation needs from you, how long things take, and what you can expect to see. No technical knowledge is needed.

## What the automation does for you

| Event | What happens automatically | What a person still does |
|---|---|---|
| New starter (joiner) | Work account created, manager set, the right teams and apps assigned, licence assigned, a one-time password produced for IT to pass on securely. | IT hands over equipment and the first-day login details. The manager welcomes the person. |
| Change of role or department (mover) | Old access that belongs to the previous role is removed, new access is added, job title and manager are updated. | The manager confirms the new access is what the person needs. |
| Leaver | Sign-in is blocked, all active sessions are ended, registered sign-in methods are removed, group access is removed, licences are released. | IT and the manager finish the checklist: mailbox, files, devices, other systems. |

Nothing is changed until IT runs the file in live mode. IT always runs a preview first and shares it with you if you ask.

## What HR must provide

Send IT one row per person in the agreed CSV format (see `samples/events.sample.csv`). Every field below matters.

### New starter

| Field | Example | Notes |
|---|---|---|
| EventType | Joiner | |
| EffectiveDate | 2026-12-03 | First working day, written year-month-day. |
| ApprovalReference | HR-2001 | Your ticket or approval number. The automation will not make live changes without one. |
| EmployeeId | NW2001 | Unique. It stops the same person being created twice. |
| GivenName, Surname | Priya, Nair | Spelled as the person wants it. Accents are handled. |
| Department | Finance | Must be one of the departments IT has set up. If it is new, tell IT before the start date. |
| JobTitle | Finance Analyst | The title decides some role-based access. |
| ManagerUpn | the manager's work sign-in name | The manager must already have an active account. |
| UsageLocation | GB | Two-letter country code. Needed before a licence can be assigned. |
| OfficeLocation | London | Optional. |

### Change of role

| Field | Notes |
|---|---|
| EventType | Mover |
| EffectiveDate | The date the new role starts. |
| ApprovalReference | Your approval number. |
| UserPrincipalName | The person's current work sign-in name. |
| Department, JobTitle, ManagerUpn, OfficeLocation | Give only what changes. At least one is required. |

### Leaver

| Field | Notes |
|---|---|
| EventType | Leaver |
| EffectiveDate | The contractual last day. Access is removed on this date, not before. |
| ApprovalReference | Your approval number. |
| UserPrincipalName | The leaver's work sign-in name. |
| MailboxConverted | Leave empty at first. IT changes it to `yes` when the mailbox has been converted to a shared mailbox, and the run is repeated to release licences. |

## Timelines

These are the defaults. IT can change them.

| Event | Send to IT | What happens | Why |
|---|---|---|---|
| Joiner | At least 5 working days before the start date | The account is prepared 3 days before the start date. | Gives IT time to order equipment and fix any data problem. |
| Mover | At least 3 working days before the effective date | Changes are made on the effective date. | Access should change when the role changes, not weeks later. |
| Leaver (planned) | At least 5 working days before the last day | Access is removed on the last day. | Gives the manager time to agree who needs the mailbox and files. |
| Leaver (urgent, for example dismissal or security concern) | Immediately, by phone as well as ticket | IT runs the leaver process straight away. | Blocking sign-in is quick and is the step that stops access. |

A row dated in the future is not ignored. The preview shows it as "Deferred" and it is picked up on the right day.

## Checklists

### Joiner checklist for HR

- [ ] Offer accepted and start date confirmed.
- [ ] Employee ID created in the HR system.
- [ ] Department and job title match a department IT supports.
- [ ] Manager named and already has a work account.
- [ ] Country of work confirmed (for the licence).
- [ ] Row sent to IT with an approval reference.
- [ ] Preview from IT checked: sign-in name, department, manager look right.
- [ ] Manager told when to expect equipment and login details.

### Mover checklist for HR

- [ ] Change approved by the current and the new manager.
- [ ] Effective date agreed.
- [ ] Row sent to IT with an approval reference.
- [ ] Preview checked: groups being removed are those of the old role.
- [ ] If the person needs temporary access to both roles, tell IT. The standard process swaps access fully.

### Leaver checklist for HR

- [ ] Resignation or termination recorded and last working day confirmed.
- [ ] Row sent to IT with an approval reference.
- [ ] Manager decides who receives the mailbox and the files, and tells IT.
- [ ] Equipment return arranged.
- [ ] Any legal hold, investigation or retention requirement flagged to IT before the last day.
- [ ] IT's checklist for the leaver received and every box ticked or marked not applicable with a reason.
- [ ] Direct reports reassigned to a new manager in the HR system.
- [ ] Account deletion date agreed (the account is blocked, not deleted, by the automation).

## What you can expect to see

* A **preview** before anything happens. It lists each person and the action planned, and marks rows that are invalid, deferred or refused.
* A **leaver checklist** for each leaver, with automated results and the manual steps still to do.
* A **batch summary** and an **audit log** that show who ran what, when, under which approval reference, and the result. See `security-considerations.md`.

## Why a row might be refused or rejected

| Message in the preview | What it means | What to do |
|---|---|---|
| Invalid: field is required | A needed column is empty. | Send the corrected row. |
| Invalid: EffectiveDate must be yyyy-MM-dd | The date is in the wrong format. | Use year-month-day, for example 2026-12-03. |
| Department is not mapped | IT has not set that department up. | Ask IT to add it before the start date. |
| Refused: protected account | The person is an emergency-access, service or administrator account, or is managed from on-premises. | Raise it with IT. These are handled by hand on purpose. |
| Deferred | The date is in the future. | Nothing. It runs when due. |
| Refused: ApprovalReference is required | A live run needs an approval number. | Send the number. |
