# Windows LAPS — the policy this deployment depends on

**This repository does not create or manage this GPO.** `pdq_ad_config` grants the PDQ service
account permission to READ LAPS passwords; something must first be setting them. That something is
this policy, and it is a precondition of the deployment rather than part of it.

Recorded from the live directory on 2026-09-03. Carried by **Default Domain Policy**
(`{31b2f340-016d-11d2-945f-00c04fb984f9}`), so it reaches every domain-joined machine.

## Registry-backed settings

Key: `HKLM\Software\Microsoft\Policies\LAPS`

| Value | Type | Setting | Why it is that |
|---|---|---|---|
| `BackupDirectory` | DWord | `2` | Back the password up to **Active Directory**. `1` would be Entra ID, which this directory does not use. |
| `PasswordAgeDays` | DWord | `30` | Rotation cadence. A managed password older than this is replaced by the client itself. |
| `PasswordLength` | DWord | `20` | |
| `PasswordComplexity` | DWord | `4` | All four character classes. |
| `PasswordExpirationProtectionEnabled` | DWord | `1` | Refuses a password whose expiry has been pushed beyond the policy age. |

## What the deployment assumes of it

- **`BackupDirectory = 2`.** The read grant `pdq_ad_config` creates is an AD ACL. A policy backing
  up to Entra would leave nothing in AD for that ACL to govern, and PDQ would find no credential.
- **The schema is extended** for Windows LAPS (`msLAPS-*` attributes). Legacy LAPS
  (`ms-Mcs-AdmPwd`) is a different schema and is NOT what this deployment reads.
- **Machines can write their own password.** Granted separately per OU; without it the attribute
  stays empty and a scan has no credential to use.

## Applying this in a new environment

Set these five values on a GPO linked so it reaches the machines PDQ will manage, then extend the
schema and grant the computer self-write. `pdq_ad_config` then grants the service account its read.
The role deliberately does not check any of this: a missing schema attribute makes
`Set-LapsPermissions.ps1` throw by name, at the point the absence matters.
