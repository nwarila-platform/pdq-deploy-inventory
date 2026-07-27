# `pdq` role — PDQ Deploy & Inventory (all-in-one Central Server)

Configures a single Windows Server end-to-end into a **PDQ Deploy & Inventory** all-in-one
**Central Server**: 3 data disks, the App Share (repository), a shared Background Service User,
both PDQ applications installed silently, Central Server mode + firewall, database relocation,
and the Deploy↔Inventory integration link.

> **Topology is fixed by design.** PDQ Deploy and PDQ Inventory integrate **only** when they run
> on the same host, in the same operating mode (Central Server), under **one** Background Service
> User (or each cross-added as a console user). This role therefore builds a single all-in-one
> host with one service account for both — the PDQ-recommended, integration-supporting topology.
> ([PDQ: Integration](https://help.pdq.com/hc/en-us/articles/4409527534747-Integration-Between-PDQ-Deploy-and-PDQ-Inventory))

## Composition

Overlaid into a pinned `nwarila-platform/ansible-framework` checkout at run time via
`scripts/compose-and-run.sh` (never run repo-side). Driven by `ansible/playbooks/pdq.yml`, which
runs `windows_disk_manager` (disk provisioning) then `pdq` (install + configure).

## Inputs

Declared in the `pdq:` override dict (playbook / `-e`), read by the loader as `config.*`.

| Key | Source | Required | Notes |
|-----|--------|----------|-------|
| `deploy_disk_id` | `config.deploy_disk_id` | **yes** | Windows `Get-Disk` UniqueId (`eui.*`) → E: `PDQDEPLOY` (Deploy DB) |
| `inventory_disk_id` | `config.inventory_disk_id` | **yes** | → F: `PDQINVENTORY` (Inventory DB) |
| `share_disk_id` | `config.share_disk_id` | **yes** | → G: `PDQSHARE` (Deploy repository / App Share) |
| `license_key` | `config.license_key` | **yes** | PDQ **Enterprise** license (Central Server + integration). `no_log`; never committed |
| `service_account.name` | `config.service_account.name` | **yes** | Local Background Service User — **one** account for both apps (default `svc-pdq`) |
| `service_account.password` | `config.service_account.password` | **yes** | Local account secret; supply via vault or a protected `-e @<file>`, never literally on the command line or committed |
| `central_server.port` | `config.central_server.port` | no (default `7337`) | Central Server TCP port; a firewall exception is created for it |
| `data_disks.*` | `config.data_disks.*` | no (defaults) | Drive letters / labels / allocation units (see `defaults/main.yml`) |
| `repository.dir_name` | `config.repository.dir_name` | no (default `AppRepo`) | Repository directory on `config.data_disks.share.drive_letter` |
| `repository.share_name` | `config.repository.share_name` | no (default `AppRepo`) | SMB share name for the repository |

`validate.yml` fails the play closed if the three disk ids or drive letters collide, or if
`license_key` / `service_account.name` are empty.

## App Share

The role derives the repository path from the dedicated share disk and repository directory:
`<config.data_disks.share.drive_letter>:\<config.repository.dir_name>` (by default
`G:\AppRepo`). It creates three explicit allow ACEs on that directory, inherited by child
folders and files:

- `BUILTIN\Users`: `ReadAndExecute`
- `BUILTIN\Administrators`: `FullControl`
- `NT AUTHORITY\SYSTEM`: `FullControl`

The SMB share is published with `Administrators` as its only full-access share principal,
using a replacement permission set and with offline caching disabled. This supports PDQ's
default Push mode and multi-admin Central Server console access. Pull Copy mode is deferred;
if enabled later, its Deploy User or group will need explicit read/write permissions at both
the share and NTFS layers.

## Background Service User

The role creates one local-only Background Service User (by default `svc-pdq`) for both PDQ
Deploy and PDQ Inventory. It adds the account to the local `Administrators` group and grants
`SeServiceLogonRight` (Log-On-as-Service). Administrators membership gives the account repository
read/write access through the `BUILTIN\Administrators: FullControl` App Share ACL implemented in
P03; no separate per-account repository ACE is required.

The account password has no default. Supply it through Ansible Vault or a non-committed,
permission-restricted extra-vars file referenced as `-e @<file>` and containing the complete
`pdq` mapping. Do not put a literal password in command-line extra vars. The complete
`ansible.windows.win_user` task is protected with `no_log: true`.

Password updates use `update_password: on_create` so converged runs remain idempotent. Consequently,
changing the configured secret does not rotate the password of an existing account; password
rotation must be performed as a separate, deliberate operation. Domain service accounts are not
supported by this local-account implementation.

## Build status

The Background Service User and App Share are implemented. The remaining install spine is built one
MS/PDQ-doc-grounded piece per cycle.

## Reference install spine (target)

Background Service User → App Share on G: (dir + SMB share + ACLs) → install PDQ Inventory (MSI
silent `Mode=Server ServerPort Licensekey /qn /norestart`) → install PDQ Deploy (same user + mode)
→ Central Server enable + firewall exception → relocate Inventory DB→F:, Deploy DB→E:, Deploy
repository→G: → verify services + Central Server port.
