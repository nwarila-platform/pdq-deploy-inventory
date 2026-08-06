# PDQ Deploy & Inventory — headless automation research

**Type:** Reference. Documentation and live measurements that ground the application-role build
queue. Compiled 2026-07-27, corrected with PDQ Inventory 20.1.8.0 measurements on 2026-07-30, and
extended with PDQ Deploy 20.1.8.0 measurements on 2026-08-05. Values that still require measurement
for later work are marked **[confirm on-VM]** and are re-researched independently before
implementation.

## Current automation surface

PDQ Inventory 20.1.8.0 installs headlessly from the WiX Burn bundle
`Inventory_20.1.8.0.exe` with `/s /norestart`. The installed application supplies CLI commands for
service mode, service credentials, console authorization, settings, system information, and
database maintenance. Installation alone does not configure those concerns.

PDQ Deploy 20.1.8.0 installs headlessly with `/s` from its vendor stub. Installation creates its
uninstall identity and service but does not configure or start the application.

| Concern | Mechanism |
|---|---|
| Inventory install | WiX Burn `.exe` bundle with `/s /norestart` |
| Deploy install | Bespoke vendor `.exe` stub wrapping one 32-bit WiX 5 MSI; silent switch `/s` |
| Central Server enable | CLI `SetServiceMode Server` |
| Background Service User | CLI `SetServiceCredentials` / `BackgroundService` |
| Integration authorization | CLI `ConsoleUsers` |
| Database location | 32-bit registry `Settings\Database\FileName` |
| Repository / App Share | `Settings` CLI or registry **[confirm on-VM]**, plus share and ACL management |
| Licence | Roles write the supplied `License` value under native 64-bit `HKLM\SOFTWARE\Admin Arsenal\<Product>` |
| Firewall | Explicit firewall rule |
| Verification | Uninstall identity, service state, and CLI `SystemInfo` where the database exists |

## CLI command inventory

`PDQInventory.exe` is installed under
`C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\`. Its v20 command inventory includes:

- `SetServiceMode` for Local, Client, or Server mode;
- `SetServiceCredentials` and `BackgroundService` for the Windows service;
- `ConsoleUsers` for accounts authorized to connect to the background service;
- `Settings` for internal settings and feature flags;
- `SystemInfo` for version and database-path information;
- database maintenance commands including `CheckDatabase`, `OptimizeDatabase`,
  `DatabaseCleanup`, `RepairDatabase`, and `RestoreDatabase`;
- Inventory operations including `ScanComputers`, `GetCollectionComputers`, `AddComputers`,
  `ADSync`, and `UpdateScanCredential`.

Live enumeration of all 47 Inventory v20 commands found no command that applies a licence. Exact
parameters for configuration commands must be confirmed on the VM before their later automation
is implemented.

## Topology

PDQ Deploy and Inventory integrate when co-located, in the same operating mode, under one
Background Service User or with the required cross-authorization. The planned Central Server
topology uses one host, TCP 7337 by default, and an Enterprise licence. The Background Service User
must be a local administrator with repository read/write access and Log-On-as-Service rights.

Sources: [Integration](https://help.pdq.com/hc/en-us/articles/4409527534747-Integration-Between-PDQ-Deploy-and-PDQ-Inventory),
[Inventory Central Server](https://docs.pdq.com/current-version/Inventory/centralserver.htm),
[Credentials](https://help.pdq.com/hc/en-us/articles/115002510472-PDQ-Deploy-Inventory-Credentials-Explained).

## Paths, registry, and measured installed identity

The measured Inventory 20.1.8.0 installation is 32-bit:

- Default database directory:
  `%ProgramData%\Admin Arsenal\PDQ Inventory\`, with `Database.db` as the primary SQLite file.
- Install directory: `C:\Program Files (x86)\Admin Arsenal\PDQ Inventory\`.
- Native 64-bit licence registry roots written by the roles:
  `HKLM\SOFTWARE\Admin Arsenal\<Product>`, where `<Product>` is `PDQ Inventory` or `PDQ Deploy`.
- MSI-owned 32-bit application registry roots:
  `HKLM\SOFTWARE\WOW6432Node\Admin Arsenal\<Product>`.
- Uninstall hive:
  `HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall`.

A clean installation produced exactly one new uninstall entry:

| Field | Measured value |
|---|---|
| Hive | `HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall` |
| Key name | `{47D90CDF-2CE4-4B71-87DD-1223B1DA0AB2}` |
| `DisplayName` | `PDQ Inventory` |
| `DisplayVersion` | `20.1.8.0` |
| `UninstallString` | `MsiExec.exe /X{47D90CDF-2CE4-4B71-87DD-1223B1DA0AB2}` |

The EXE is a Burn delivery bundle, while its only observed Add/Remove Programs identity is the
inner MSI registration above. The installer creates the `PDQInventory` service in Stopped and
Disabled state.

## Database relocation

The 32-bit installation changes the registry path required by later relocation work. For
Inventory, the candidate setting is:

`HKLM\SOFTWARE\WOW6432Node\Admin Arsenal\PDQ Inventory\Settings\Database\FileName`

The measured Deploy installation is also 32-bit, but a clean install has no `Settings` tree. Later
relocation work must verify the Deploy settings root after the first service or console run before
changing it.

The supported procedure remains: stop the background service, create the `FileName` string with
the full target database path, copy the database, and restart the service. Whether companion files
such as `log.db`, `Database.db-wal`, and `Database.db-shm` follow `Database.db` remains
**[confirm on-VM]**.

Source: [Modify Database Location](https://help.pdq.com/hc/en-us/articles/360041178091-Modify-Database-Location).

## Inventory 20.1.8.0 install and licensing measurements

The shipped artifact is `Inventory_20.1.8.0.exe`, a WiX Burn bundle rather than an MSI download.
Inspection of its inner MSI property table found no `Mode`, `ServerName`, `ServerPort`, or
`Licensekey` properties, so the earlier silent-MSI property set does not exist in v20. Server mode
and its port are post-install configuration, not installer arguments.

The inner table does contain uppercase `LICENSE`, but passing `LICENSE=` during a measured install
had no visible effect: the registry `License` value remained one character, and licensing
information was not available from the CLI before the database existed. Together with the
measured absence of a licensing CLI command, this confirms the installer does not apply a licence.
The roles write the supplied value to the native 64-bit registry; mode selection remains later work.

The measured silent invocation is:

```text
Inventory_20.1.8.0.exe /s /norestart
```

Clean and repeat invocations returned `0`; the measured bundle never returned `3010`. The
uninstall registration was present and the service was Stopped and Disabled when the clean install
exited. Re-running the bundle over that existing installation changed nothing. The bundle
therefore supplies no idempotency signal of its own; automation must classify the installed
identity before deciding whether to run it.

## Deploy 20.1.8.0 install measurements — measured 2026-08-05

The Deploy installer is a bespoke vendor stub wrapping one 32-bit WiX 5 MSI, not a WiX Burn
bundle. Its embedded switch table is exactly `/s /S /p /P /x /X`. The measured silent invocation
is:

```text
PDQ_Deploy_x86-x64.exe /s
```

Clean and repeat silent invocations returned `0` with no reboot, and the wrapper waited
synchronously for installation to finish. Re-executing it over an installed product performs a
full MSI reconfiguration; it is never a no-op. Automation must therefore classify the installed
identity before deciding whether to run the stub.

The measured uninstall identity exists only in the 32-bit registration hive; the corresponding
native hive was empty:

| Field | Measured value |
|---|---|
| Hive | `HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall` |
| ProductCode / key name | `{4E9FA177-A200-4DFC-9DC6-9D0290FCAAC2}` |
| `DisplayName` | `PDQ Deploy` |
| `DisplayVersion` | `20.1.8.0` |
| `Publisher` | `PDQ.com` |

The install root is `C:\Program Files (x86)\Admin Arsenal\PDQ Deploy\`. The installer creates one
service, `PDQDeploy`, under `LocalSystem`; it was installed Stopped and Disabled and was never
started by the installer.

Before any service or console run, the application configuration registry footprint is a single
`License` string value of length one. There is no `Settings` tree and no `%ProgramData%\Admin
Arsenal` tree until the first service or console run.

## Download and artifact delivery

The measured release endpoint was public, unauthenticated, and versioned, and its release metadata
published a SHA-256. That availability does not change the source decision: deployment uses the
account-local artifact bucket as its canonical, audited source for reproducibility and controlled
access.

The current object layout uses the flat `applications/pdq/` prefix, not version subdirectories:

```text
applications/pdq/Inventory_20.1.8.0.exe
```

Using its ambient AWS credentials, the controller derives the credentials' account-local
`<account-id>-ansible` bucket, downloads the object, verifies its SHA-256, and only then transfers
it to the target. The role performs no identity transition, and supplying credentials is the
caller's responsibility. The ambient identity must itself hold the artifact grant; merely being
able to assume an identity that holds it is insufficient. Credentials from another account derive
that other account's bucket. The target holds no AWS credential.

## Open confirmations

- Exact configuration-command parameters on the installed versions.
- The repository setting used by later automation.
- Companion-file behavior during database relocation.
