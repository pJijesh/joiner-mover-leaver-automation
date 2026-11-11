# Permissions

This page lists the Microsoft Graph permissions the module asks for, the cmdlet that needs each one, and the Entra role the signed-in administrator also needs.

**How this was checked.** Each cmdlet name and parameter was checked against Microsoft Graph PowerShell SDK 2.41.2 (`GraphContract.Tests.ps1` does this automatically when the SDK is installed). Each permission was checked against the Microsoft Learn Graph API reference pages for the underlying call on 11 November 2026, and against `Find-MgGraphCommand`, which lists the permissions the SDK itself documents for a cmdlet. Microsoft changes these pages. Re-check before granting consent in a production tenant.

## Two layers of access

Delegated sign-in needs both:

1. a **Graph permission (scope)** that the administrator consents to, and
2. a **Microsoft Entra role** held by the person who signs in.

The permission says what the app may ask for. The role says what the person may actually do. The effective access is the overlap.

## Delegated scopes requested per operation

`Connect-JmlGraph -Operation <name>` requests exactly these.

| Scope | Joiner | Mover | Leaver |
|---|:-:|:-:|:-:|
| `User.ReadWrite.All` | yes | yes | |
| `User.Read.All` | | | yes |
| `User.EnableDisableAccount.All` | | | yes |
| `User.RevokeSessions.All` | | | yes |
| `GroupMember.ReadWrite.All` | yes | yes | yes |
| `Group.Read.All` | yes | yes | yes |
| `UserAuthenticationMethod.ReadWrite.All` | | | yes |
| `LicenseAssignment.ReadWrite.All` | | | yes |

`Connect-JmlGraph -Operation All` requests the union. Before each command runs, the module compares the granted scopes with the operation's needs and stops early with a clear message when one is missing. A broader permission that Microsoft documents as covering a narrower one is accepted (for example `Group.ReadWrite.All` for `GroupMember.ReadWrite.All`).

## Why each permission

| Cmdlet | Graph call | Scope used | Why |
|---|---|---|---|
| `Get-MgUser` | `GET /users` with a filter | `User.ReadWrite.All` or `User.Read.All` | Find a person by sign-in name or employee ID, read department, title, enabled state, sync state and licence assignment states. |
| `New-MgUser` | `POST /users` | `User.ReadWrite.All` | Create the account. Microsoft lists `User.Create` as the least privileged permission for creation alone, but a joiner also updates attributes and sets the manager, which needs `User.ReadWrite.All`. |
| `Update-MgUser` | `PATCH /users/{id}` | `User.ReadWrite.All` for attributes. `User.EnableDisableAccount.All` with `User.Read.All` for blocking sign-in. | Department, title, office changes (mover). Disable the account (leaver). Microsoft documents `User.EnableDisableAccount.All` plus `User.Read.All` as the least privileged pair for `accountEnabled`. |
| `Set-MgUserManagerByRef` | `PUT /users/{id}/manager/$ref` | `User.ReadWrite.All` | Set the line manager. |
| `Get-MgUserManager`, `Get-MgUserDirectReport` | `GET /users/{id}/manager`, `/directReports` | `User.Read.All` (or `User.ReadWrite.All`) | Snapshot for the leaver handover notes and to compare managers. |
| `Get-MgUserMemberOf` | `GET /users/{id}/memberOf` | `User.Read.All` with `GroupMember.ReadWrite.All` / `Group.Read.All` | List groups and directory roles, to decide what to remove and to detect administrators. Without group read permission, group names come back empty. |
| `Get-MgGroup` | `GET /groups` | `Group.Read.All` | Look up a group by name and check whether it is dynamic, role-assignable, synced or mail-enabled. |
| `New-MgGroupMember` | `POST /groups/{id}/members/$ref` | `GroupMember.ReadWrite.All` | Add a person to a group. This includes the licence group, which triggers group-based licensing. |
| `Remove-MgGroupMemberByRef` | `DELETE /groups/{id}/members/{id}/$ref` | `GroupMember.ReadWrite.All` | Remove a person from a group. Always the `$ref` form, so the user object is never deleted. |
| `Revoke-MgUserSignInSession` | `POST /users/{id}/revokeSignInSessions` | `User.RevokeSessions.All` | End refresh tokens and sessions. |
| `Get-MgUserAuthenticationMethod` | `GET /users/{id}/authentication/methods` | `UserAuthenticationMethod.ReadWrite.All` (read-only `.Read.All` would do for listing) | List registered methods. |
| `Remove-MgUserAuthentication*Method` (phone, authenticator, FIDO2, Windows Hello for Business, software OATH, temporary access pass, email) | `DELETE /users/{id}/authentication/...Methods/{id}` | `UserAuthenticationMethod.ReadWrite.All` | Remove registered methods. The password method cannot be deleted and is skipped. A phone that is the default method cannot be deleted by Entra, and the module records that as skipped with the reason. |
| `Set-MgUserLicense` | `POST /users/{id}/assignLicense` | `LicenseAssignment.ReadWrite.All` | Remove directly assigned licences. Licences from groups are reclaimed by removing the person from the licence group. |
| `Connect-MgGraph`, `Get-MgContext` | sign-in | none | Connect with the scopes above. Read the granted scopes and the signed-in account. |

Permissions the module deliberately does not request: `Directory.ReadWrite.All`, `User.ReadWrite.All` for leavers, `Group.ReadWrite.All`, `RoleManagement.ReadWrite.Directory`, `Application.ReadWrite.All`.

## Entra roles for the signed-in administrator

Microsoft Learn lists these as the least privileged built-in roles for each call. Use Privileged Identity Management to activate them only when needed.

| Task | Least privileged role (delegated) |
|---|---|
| Create users, update attributes, set manager, add and remove group members | User Administrator (group membership can also be done by Groups Administrator or the group owner) |
| Disable an account | Microsoft Learn says a Privileged Authentication Administrator is the least privileged role for administrator accounts (which this tool refuses anyway) and points to its "who can perform sensitive actions" table for other users. A User Administrator is the usual role for ordinary accounts. Confirm against that table. |
| Assign or remove licences | License Administrator or User Administrator |
| List authentication methods | Global Reader, Authentication Administrator or Privileged Authentication Administrator |
| Delete authentication methods | Authentication Administrator or Privileged Authentication Administrator |
| Revoke sessions | The Learn page names no role. Use a role that includes the right to invalidate refresh tokens, for example User Administrator, and confirm in a test tenant. |

A person holding all of these at once is highly privileged. Consider splitting joiner and mover duties (User Administrator, Groups Administrator) from leaver duties (adds Authentication Administrator).

## Unattended (app-only) use

`Connect-JmlGraph -TenantId <tenant> -ClientId <app> -CertificateThumbprint <thumbprint>` signs in as an app registration with a certificate. You grant **application permissions** and admin consent in the portal, because app-only sign-in does not request scopes.

Application permissions needed (the equivalents of the table above):

* `User.ReadWrite.All`, `User.EnableDisableAccount.All`, `User.RevokeSessions.All`
* `GroupMember.ReadWrite.All`, `Group.Read.All`
* `Directory.Read.All` (Microsoft lists this as the application permission for listing a user's `memberOf`, which the module uses to detect administrator roles)
* `UserAuthenticationMethod.ReadWrite.All`
* `LicenseAssignment.ReadWrite.All`

Some operations also need the app's service principal to hold an Entra role (Microsoft documents this for `accountEnabled` and for authentication methods). Assign the least privileged role that works and review it periodically.

In an app-only session Graph reports roles instead of scopes, so the module warns, and does not stop, when it cannot match a scope. The first Graph call confirms whether access is really present. This path is documented but has not been run against a real tenant (see `testing-status.md`).

Protect the certificate: non-exportable private key, stored in the machine or a managed vault, access limited to the run account, and a short validity period with a rotation reminder.

## Microsoft Graph PowerShell SDK modules

```powershell
Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Users.Actions, `
    Microsoft.Graph.Groups, Microsoft.Graph.Identity.SignIns -Scope CurrentUser
```

Not needed for the tests. The tests mock every call.

## Sources

* Microsoft Learn, Microsoft Graph permissions reference and the Graph REST API pages for: update user, create user, assign manager, list memberOf, list directReports, assignLicense, revokeSignInSessions, add and remove group member, list authentication methods, delete phone authentication method.
* Microsoft Graph PowerShell SDK, `Find-MgGraphCommand`, version 2.41.2.
