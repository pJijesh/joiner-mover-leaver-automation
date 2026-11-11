# Testing status

This page states exactly what was run, with what result, and what was not run. Nothing here is a claim about behaviour in a real tenant.

## Environment used

| Item | Value |
|---|---|
| Operating system | Linux (container) |
| PowerShell | 7.4.6 |
| Pester | 5.7.1 |
| PSScriptAnalyzer | 1.25.0 |
| Microsoft Graph PowerShell SDK | 2.41.2 (Authentication, Users, Users.Actions, Groups, Identity.SignIns), used only for the signature check below |
| Mermaid CLI | 11.16.0 (`mmdc`) |
| Date of the run | 11 November 2026 |

## What was run, and the result

| Check | Command | Result |
|---|---|---|
| Unit and behaviour tests | `pwsh -File scripts/Invoke-Checks.ps1` (runs `Invoke-Pester ./tests`) | 134 passed, 0 failed, 0 skipped with the Graph SDK installed |
| Same tests with the Graph SDK hidden, as CI will see them | same command after moving the SDK modules out of the module path | 112 passed, 0 failed, 22 skipped (the 22 skipped are the SDK signature checks) |
| Static analysis of `src` | `Invoke-ScriptAnalyzer -Path ./src -Recurse -Severity Warning,Error` (inside `Invoke-Checks.ps1`) | No findings. Three informational `PSUseOutputTypeCorrectly` notes were not treated as failures. |
| Static analysis of `tests` and `scripts` | same script, excluding `PSAvoidGlobalVars`, `PSReviewUnusedParameter`, `PSUseShouldProcessForStateChangingFunctions`, `PSUseSingularNouns`, `PSAvoidUsingWriteHost` | No findings. The exclusions exist because test fixtures use a shared in-memory tenant and a console script prints progress. |
| Graph cmdlet and parameter names | `tests/GraphContract.Tests.ps1` against SDK 2.41.2 | All 22 cmdlets used by the module exist and accept every parameter the stubs declare. |
| Graph permission lookup | `Find-MgGraphCommand` for the write cmdlets, plus Microsoft Learn pages | Matches `permissions.md`. `New-MgGroupMember` returned no entry from `Find-MgGraphCommand`. The Learn page for adding a group member was used instead. |
| Diagram rendering | `mmdc` with a no-sandbox Chromium configuration | Four diagrams rendered to PNG. The overview and leaver diagrams were inspected by eye. |

## What the tests cover

| File | Focus |
|---|---|
| `Joiner.Tests.ps1` | `-WhatIf` changes nothing, creation with forced password change, password never in the log, credential hand-over, idempotency, repair of an existing account, name collisions, licence overrides, role groups by title, validation failures, disabled-account refusal, skipped dynamic groups, missing group, connection and scope errors, audit lines. |
| `Mover.Tests.ps1` | Preview, group swap, baseline kept, manual groups untouched, add-before-remove ordering for licences, idempotency, title-only change, manager change, failures, skipped dynamic group, partial failure, seven protection cases (break-glass by pattern and name, administrator role, protected group, synced, disabled, self). |
| `Leaver.Tests.ps1` | Preview with checklist, full leaver run with licence hold, release with `-MailboxConverted`, authentication methods, `-SkipMfaReset`, default method tolerated, idempotency, `ManagedOnly`, checklist content, user not found, partial failure, protection cases, scope check, audit flags. |
| `Batch.Tests.ps1` | Dry run default, classification of every sample row, accent and apostrophe names, audit dry-run flags, `-Execute -WhatIf`, limit warnings and refusal, full execute on the sample file, no password in audit or summary, approval reference, invalid rows, `-StopOnError`, lead days, case-insensitive columns, missing and empty files, second run safe. |
| `Config.Tests.ps1` | Configuration validation and error collection, environment overrides, defaults, group mapping, audit log format, redaction, log path rules, fail-closed on audit failure, name slugs, collision numbering, password quality, scope sets, connect behaviour, and a repository scan for forbidden terms, long dashes, non-example email domains and secret-like strings. |
| `GraphContract.Tests.ps1` | Mock signatures against the real SDK, when installed. |

All Graph calls are mocked with an in-memory tenant (`tests/Helpers/FakeTenant.ps1`). All data is synthetic and uses `northwind.example`.

## What was not run

* **No live tenant.** Nothing in this repository has been executed against Microsoft Entra ID or Microsoft Graph. Real behaviour may differ: replication delay after creating a user or group, throttling, group-based licensing timing, conditional errors for protected objects, and exact error text.
* **No sign-in paths.** `Connect-JmlGraph` was tested with `Connect-MgGraph` mocked. Interactive, device-code and certificate sign-in were not exercised.
* **No app-only permission check.** The application permission list in `permissions.md` is taken from documentation, not from a working app registration.
* **No other platforms or versions.** Windows, macOS and PowerShell 7.2 and 7.3 were not tested. The manifest declares PowerShell 7.2 as the minimum, and CI uses the runner's current PowerShell 7.
* **The CI workflow has not been executed on GitHub.** It is written to run the same script that was run here. Its first run on GitHub is the real test.
* **Pester 6 was not used.** The scripts pin Pester to version 5.
* **Mermaid on GitHub.** The diagrams were rendered locally. How GitHub renders the Mermaid blocks was not checked.
* **No security review by a third party and no penetration test.**
* **No load test.** Batch limits default to 25 events and 5 leavers.
* **Manual leaver steps** (shared mailbox conversion, OneDrive access, device retirement) are described in the checklist. They are not automated and were not tested.

## Defects found and fixed during completion

| Area | Problem | Fix |
|---|---|---|
| Result status | A live run always reported `Succeeded` or `PartiallySucceeded`, even when nothing changed, because the bookkeeping `Start` record counted as work. | `New-JmlResult` now ignores `Start` and `Complete` records when it works out the status. A re-run of a joiner or mover now reports `NoChange`. |
| Audit detail | The yes/no facts `passwordGenerated` and `forceChangePasswordNextSignIn` were redacted because their names contain "password". | Those two boolean keys are exempt. Any other key that looks secret is still redacted. |
| Test fixtures | A test used the variable name `Args`, which clashes with the PowerShell automatic variable and made the joiner tests fail to bind parameters. The Graph mocks read `$PSBoundParameters`, which is empty inside Pester mocks. | Renamed the variable. Mocks now read `$PesterBoundParameters`. |
