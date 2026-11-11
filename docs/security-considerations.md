# Security considerations

This page explains the controls built into the automation and the controls your organisation still needs around it. It is written for security reviewers, auditors and IT managers.

## Principles

1. **Dry run first.** A batch run changes nothing unless `-Execute` is passed. Each worker command supports `-WhatIf`.
2. **Least privilege.** Each operation requests only the permissions it needs (see `permissions.md`). A joiner session cannot reset authentication methods. A leaver session cannot create users.
3. **Allow lists over block lists for access changes.** The automation only adds or removes groups that are named in `config/department-groups.json` and `config/licences.json`. Anything else a person belongs to is left alone during a move.
4. **Refuse by default for privileged and special accounts.** See the next section.
5. **Approval gates.** A live batch row needs an approval reference. The reference is stored in the audit log.
6. **Everything is recorded.** One JSON line per action, including dry runs, with no secrets.
7. **Fail closed on audit.** If the audit log cannot be written, a live run stops before it changes anything.

## Privileged and break-glass accounts

The automation never modifies:

* accounts listed by name or pattern in `config/protected-accounts.json` (break-glass accounts, service accounts and admin accounts by default: `breakglass*@*`, `svc-*@*`, `admin-*@*`);
* accounts whose object ID is listed in the same file;
* members of the protected groups named in the file;
* holders of any Entra directory (administrator) role, detected at run time from the person's memberships;
* accounts synced from on-premises Active Directory, because the source of authority is on-premises;
* the account that is running the automation.

The same checks apply to groups. The automation will not change membership of a protected group, a dynamic group, a role-assignable group, a synced group or a mail-enabled group. Role-assignable groups would need the `RoleManagement.ReadWrite.Directory` permission, which this project never requests.

Operational advice:

* Keep two or more emergency-access accounts that are cloud-only, excluded from Conditional Access policies as your policy requires, and listed in `protected-accounts.json`.
* Put them in a protected group as well, so that two independent checks apply.
* Review the protected list whenever a privileged or service account is created.
* Alert on any sign-in by an emergency-access account. That is outside this tool.

## Approval gates

| Gate | Where | Effect |
|---|---|---|
| Dry run by default | `Invoke-JmlBatch` | No tenant change without `-Execute`. |
| `-WhatIf` and confirmation | each worker command | `ConfirmImpact` is High, so a manual run asks before each change unless `-Confirm:$false` is given. |
| Approval reference | batch, `batch.requireApprovalReference` | A row without a reference is refused in a live run. |
| Size limits | batch, `batch.maxEventsPerRun`, `batch.maxLeaversPerRun` | A live run over the limit is refused before any change. A dry run warns. |
| Due date | batch | Future-dated events are deferred. |
| Mailbox gate | leaver, `leaver.requireMailboxConversionBeforeLicenceRemoval` | Licences are held until the mailbox is confirmed converted. |
| Person approves the file | process | The CSV should be approved by HR and a second person in IT before `-Execute`. The tool records the reference but cannot enforce who approved. |

## Least privilege in practice

* Use a dedicated administrator identity for the run, not a daily-use account. Give it only the Entra roles listed in `permissions.md`, activated just in time through Privileged Identity Management where available.
* Interactive use requests delegated scopes per operation. `Connect-JmlGraph -Operation Joiner` does not request leaver permissions.
* For scheduled use, use an app registration with a certificate, never a shared secret in a script, and grant the application permissions listed in `permissions.md` only.
* Restrict who can run the module and who can edit the configuration folder. A change to `protected-accounts.json` is a security change and should be reviewed like code.

## Passwords and secrets

* The one-time password is generated with the operating system's cryptographic random number generator, 20 characters by default (16 to 64 allowed), with upper case, lower case, digits and symbols, and without look-alike characters.
* It is held as a `SecureString`, converted to plain text only for the moment the Graph request needs it, and `forceChangePasswordNextSignIn` is set.
* It is returned to the caller as a `SecureString` or handed to a `-CredentialHandler` script block that you supply (for a vault or a secure messaging channel). It is never written to the audit log, the batch summary or the leaver checklist. Tests check this.
* The repository contains no tenant identifiers, credentials or certificates. Tenant and certificate details are supplied at run time. `.gitignore` excludes logs and output.
* Treat the returned password as a secret in your own scripts. Do not print it, do not email it in plain text.

## Audit log

* Format: JSON Lines, one object per action. Fields: schema version, UTC timestamp, run ID, actor, host, module version, operation, target, action, result, whatIf flag, approval reference, detail, error.
* One file per UTC day by default in `./logs`, or the path in `JML_LOG_PATH`, or `-AuditLogPath`.
* Values whose key looks like a password, secret, token or credential are replaced with `[redacted]`. Strings that contain such assignments are scrubbed. Long values are truncated. This is a safety net, not a licence to put secrets in detail fields.
* The log contains personal data (names, sign-in names, group names). Apply your retention and access rules. Under UK GDPR, keep it only as long as you have a documented need.
* A local file can be edited by an administrator. For stronger assurance, forward the logs to a write-once store or your SIEM, and correlate with the Entra audit log, which Microsoft records independently.

## Behaviour that protects against mistakes

| Risk | Control |
|---|---|
| Duplicate accounts | Idempotent joiner keyed on employee ID. |
| Wrong person matched | User lookup uses exact UPN or employee ID. More than one match is an error. |
| OData injection through a name | Single quotes in filter values are escaped. |
| Removing access the person should keep | Mover only touches named groups. Baseline groups are kept. |
| Re-enabling someone who left | Joiner refuses an existing disabled account. |
| Mailbox lost on licence removal | Licence hold until conversion is confirmed. |
| One bad row stops everything | Rows are isolated. `-StopOnError` is available when the opposite is wanted. |
| Runaway file | Size limits and a leaver limit per run. |
| Throttling and replication delay | Retries with back-off on newly created objects. |

## Defaults for `config/settings.json`

Any key left out falls back to these built-in values.

| Setting | Default | Meaning |
|---|---|---|
| `joiner.leadDays` | 3 | Days before the start date that a joiner is prepared. |
| `joiner.passwordLength` | 20 | One-time password length, 16 to 64. |
| `leaver.groupRemoval` | `All` | `All` removes every group the automation may change. `ManagedOnly` removes only mapped groups. |
| `leaver.resetMfaMethods` | true | Remove registered authentication methods, except the password and any method Entra will not delete. |
| `leaver.requireMailboxConversionBeforeLicenceRemoval` | true | Hold licences until `-MailboxConverted`. |
| `batch.maxEventsPerRun` | 25 | Largest number of due events in one live run. 0 means no limit. |
| `batch.maxLeaversPerRun` | 5 | Largest number of due leavers in one live run. 0 means no limit. |
| `batch.requireApprovalReference` | true | A live row needs an approval reference. |
| `audit.directory` | `./logs` | Where audit files go. |
| `output.directory` | `./output` | Where checklists and batch summaries go. |

## Known gaps and how to close them

* The tool cannot enforce that a second person approved the CSV. Use a change process or pull request on the CSV.
* Mailbox, OneDrive, device and third-party application steps are manual. They appear in the leaver checklist.
* Removing registered authentication methods needs a privileged authentication role. If that is not acceptable, set `leaver.resetMfaMethods` to false. Sign-in is blocked and sessions are revoked regardless.
* A blocked account's already-issued access tokens remain valid until they expire, unless the application supports continuous access evaluation. Revoking sessions invalidates refresh tokens. Plan for the short window that remains.
* Hybrid environments need the on-premises step done by the directory team. The tool refuses synced accounts rather than guess.
* The module has not been tested against a live tenant. See `testing-status.md` and run in a test tenant first.
