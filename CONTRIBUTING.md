# Contributing

Issues and pull requests are welcome. Please keep changes small and focused.

## Ground rules

* **Synthetic data only.** Use the invented organisation `northwind.example` and invented people. Never commit a real tenant ID, user, domain, client name, credential or certificate. A test scans the repository for common mistakes, but it is a safety net, not a review.
* **Safe by default.** Anything that changes a directory must support `-WhatIf`, be idempotent, and write an audit record. Protected accounts must stay protected.
* **No secrets in logs.** Do not add a detail field that could hold a password, token or key.
* **British English** in documentation and messages, plain professional tone, and no long dashes.

## Before you open a pull request

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser
./scripts/Invoke-Checks.ps1
```

The script runs PSScriptAnalyzer and Pester, the same as the CI workflow. Graph is mocked, so no tenant or SDK is needed. Add a test for each behaviour you change. If you add a Graph cmdlet, add its signature to `tests/Helpers/GraphStubs.ps1`, update `docs/permissions.md` with the permission Microsoft documents for it, and say how you checked it.

## Reporting a security problem

Do not open a public issue for a vulnerability. Contact the author through the LinkedIn profile on the README and describe the problem without posting exploit details.
