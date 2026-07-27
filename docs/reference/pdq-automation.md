# PDQ Deploy & Inventory — headless automation research (P0 grounding)

**Type:** Reference. Vendor-doc-grounded research that grounds the `pdq` role build queue. Compiled
2026-07-27. Where a value must be confirmed on the live VM at piece time, it is marked **[confirm
on-VM]** — the strict cycle re-researches per piece, this doc is the baseline.

## TL;DR — is a fully headless (GUI-free) install feasible? **Yes.**

PDQ is automatable end-to-end over SSH+PowerShell with **four mechanisms**, no GUI:

| Concern | Mechanism | Ansible module |
|---|---|---|
| Install both apps | **MSI silent** (`Mode`, `ServerName`, `ServerPort`, `Licensekey`, `/qn /norestart`) | `win_package` |
| Central Server enable | **CLI** `SetServiceMode Server` | `win_command` / `win_shell` |
| Background Service User | **CLI** `SetServiceCredentials` / `BackgroundService` | `win_command` (+ `no_log`) |
| Integration authorize | **CLI** `ConsoleUsers` (cross-add the shared service user) | `win_command` |
| **Database location** | **Registry** `HKLM\SOFTWARE\Admin Arsenal\PDQ <app>\Settings\Database` → `FileName` | `win_regedit` |
| Repository / App Share | `Settings` CLI or registry **[confirm on-VM]** + `win_share` + ACLs | `win_shell` / `win_regedit`, `win_share`, `win_acl` |
| License | **MSI `Licensekey=`** property at install (NOT in CLI) | `win_package` (`no_log`) |
| Firewall (7337) | MSI firewall option OR explicit rule | `win_firewall_rule` |
| Verify | **CLI** `SystemInfo` (emits version + database path) | `win_command` |

The only two things NOT exposed by the CLI are **database location** (→ registry) and **license**
(→ MSI property). Everything else has a first-class CLI command. Sources:
[Deploy CLI reference](https://docs.pdq.com/current-version/Deploy/cli-deploy-reference.htm),
[Inventory CLI reference](https://docs.pdq.com/current-version/Inventory/cli-inventory-reference.htm).

## CLI command inventory (the automation surface)

`PDQDeploy.exe` / `PDQInventory.exe` (in `C:\Program Files\Admin Arsenal\PDQ <app>\`), elevated
shell, syntax `[Program] [Command] [Parameters]`; `<Program> Help <Command>` prints exact syntax
**[confirm exact params on-VM — the online reference omits per-command parameter detail]**.

Config-relevant commands present in BOTH apps:
- **`SetServiceMode`** — "run in Local, Client, or **Server** mode" → this is the Central Server toggle.
- **`SetServiceCredentials`** — "Updates the Windows service account credentials used by the background service" → the Background Service User.
- **`BackgroundService`** — start/stop + update service account.
- **`ConsoleUsers`** — "Lists, adds, or removes Windows accounts authorized to connect to the background service" → integration + client authorization.
- **`Settings`** — "Reads or writes internal settings and feature flags" → likely repository path / port **[confirm keys on-VM]**.
- **`SystemInfo`** — "version and database path" → idempotency probe + verification.
- DB maintenance: `CheckDatabase`, `OptimizeDatabase`, `DatabaseCleanup`, `RepairDatabase`, `RestoreDatabase`.
- Deploy-only: `Deploy`, `StartSchedule`, `Import/ExportPackages`, `UpdateDeployCredential`, `TestCredential`.
- Inventory-only: `ScanComputers`, `GetCollectionComputers`, `AddComputers`, `ADSync`, `UpdateScanCredential`.

## Topology (design invariant — already locked)

PDQ Deploy + Inventory integrate ONLY co-located, same operating mode (Central Server), under ONE
Background Service User (or each cross-added via `ConsoleUsers`). Separate hosts = standalone, no
integration. Central Server: one server console holds the D&I databases + repository + background
service; clients connect on **TCP 7337** (default, configurable). **Enterprise license required.**
Sources: [Integration](https://help.pdq.com/hc/en-us/articles/4409527534747-Integration-Between-PDQ-Deploy-and-PDQ-Inventory),
[Central Server (Inventory)](https://docs.pdq.com/current-version/Inventory/centralserver.htm),
[Central Server blog](https://www.pdq.com/blog/central-server/).

The Background Service User must be a local admin with R/W to the repository and needs **Log On as a
Service** (PDQ auto-grants it if missing). Domain or local account both work.
Source: [Credentials](https://help.pdq.com/hc/en-us/articles/115002510472-PDQ-Deploy-Inventory-Credentials-Explained).

## Paths & registry (defaults)

- Databases: `%ProgramData%\Admin Arsenal\PDQ Inventory\` and `…\PDQ Deploy\` — primary file
  `Database.db` (SQLite). ([maintain-database](https://docs.pdq.com/current-version/Inventory/maintain-database.htm))
- Install dir: `C:\Program Files\Admin Arsenal\PDQ <app>\` (note: PDQ still uses the legacy "Admin
  Arsenal" vendor name in paths + registry despite the rebrand).
- Registry root: `HKLM\SOFTWARE\Admin Arsenal\PDQ <app>\`.
- The MSI auto-caches to `C:\Windows\Downloaded Installations\Admin Arsenal\PDQ <app>\<version>\`.

## Database relocation (the hardest piece — P09/P10)

**Supported registry procedure** ([Modify Database Location](https://help.pdq.com/hc/en-us/articles/360041178091-Modify-Database-Location),
[community: move DB+repo](https://help.pdq.com/hc/en-us/community/posts/360072003732-Moving-database-and-repository-from-one-disk-to-another)):

1. Close the console; **stop the background service** (`BackgroundService Stop` / `win_service`).
2. Create `HKLM\SOFTWARE\Admin Arsenal\PDQ Inventory\Settings\Database`; add **String** value
   **`FileName`** = full target path (e.g. `F:\Admin Arsenal\PDQ Inventory\Database.db`). Deploy is
   the analogous `…\PDQ Deploy\Settings\Database\FileName` → `E:\…`.
3. Copy the existing DB directory to the new location.
4. Start the service / open the console.

> **⚠ Load-bearing caveat [confirm on-VM].** Community guidance states the `FileName` value moves
> **only `Database.db`** — the companions (`log.db`, `Database.db-wal`, `Database.db-shm`) may still
> be created in the default `%ProgramData%` path. Current official docs mention only `Database.db`.
> The P09/P10 P0 MUST verify on the live VM which files actually land on E:/F: and whether the whole
> working set relocates; if only `Database.db` moves, decide (with the Director) whether that
> satisfies the "DB on its own disk" intent or a junction/symlink or newer supported method is needed.
> This is the single biggest open technical risk in the build.

## Install (MSI silent) — P06/P07

Properties are **case-sensitive** ([Case-Sensitive Silent Switches](https://help.pdq.com/hc/en-us/articles/220509407-Case-Sensitive-Silent-Switches-Parameters)).
Documented set: `Mode` (Server|Client|Local), `ServerName`, `ServerPort`, `Licensekey`. Example
([Getting Started](https://help.pdq.com/hc/en-us/articles/360058253252-Getting-Started-With-PDQ-Deploy-Inventory)):

```
msiexec.exe /i "PDQInventory_<ver>.msi" Mode=Server ServerPort=7337 Licensekey=<KEY> /qn /norestart
```

No documented MSI property sets the database directory or install dir **[confirm on-VM]** — treat DB
location as a post-install registry step, not an MSI property. License applies at install via
`Licensekey=` (`no_log`).

## Download & versioning — resolves the "pin vs latest" decision

PDQ's downloads are **form-gated** (`landing.pdq.com/download-form`); only beta/nightly have direct
redirectors (`link.pdq.com/dl-{deploy,inventory}-{beta,nightly}`). There is **no clean static,
versioned, public MSI URL**. Older versions + release notes: [pdq.com/releases](https://www.pdq.com/releases/),
[Downloads](https://www.pdq.com/downloads/). Deploy and Inventory are **separate** MSIs (~v20.x).

**→ Decision: pin specific MSI versions and self-host them in the artifact bucket** (the wazuh
pattern — `<account-id>-ansible/applications/pdq/<version>/PDQ{Deploy,Inventory}_<ver>.msi`), fetched
with a checksum gate, rather than downloading from PDQ at deploy time. Gives reproducible, offline,
version-pinned installs and side-steps the form gate. This is the strongest wazuh lesson to fold in.

## Resolved decisions (READMAP §3 — Director to confirm)

1. **MSI versioning → PIN + self-host in the artifact bucket** (above). Reproducible + offline.
2. **Service account → role-created LOCAL account** (`svc-pdq`) for the Background Service User: the
   AIO single-server model is self-contained, local admin + Log-On-as-Service + share R/W all work
   locally, and it avoids a domain dependency for the dev loop. (Target/scan credentials used to
   reach *managed* clients are a SEPARATE, later concern — likely a domain deploy credential — not
   the service user.) Overridable to a domain account.
3. **License → `-e`/vault at runtime**, applied via MSI `Licensekey=` (`no_log`); never committed.
4. **DB relocation → registry `FileName`** (above), with the WAL/companion-file behavior confirmed
   on-VM at P09/P10 before it is trusted.

## Open confirmations (do at the consuming piece's P0)

- Exact `SetServiceMode` / `SetServiceCredentials` / `Settings` parameter syntax (`<app> Help <cmd>` on-VM).
- Whether the repository path is set via `Settings` CLI vs a registry value (P11).
- WAL/`-wal`/`-shm`/`log.db` relocation behavior (P09/P10 — see caveat).
- System requirements for Windows Server 2025 + .NET prerequisites (Zendesk pages were bot-blocked).
- Whether a single "PDQ Deploy & Inventory" unified installer now exists vs the two separate MSIs.
