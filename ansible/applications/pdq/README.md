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
| `service_account.name` | `config.service_account.name` | **yes** | Background Service User — **one** account for both apps; local admin, R/W to the App Share |
| `service_account.password` | `config.service_account.password` | conditional | For a role-created local account; via `-e`/vault, never committed |
| `central_server.port` | `config.central_server.port` | no (default `7337`) | Central Server TCP port; a firewall exception is created for it |
| `data_disks.*` | `config.data_disks.*` | no (defaults) | Drive letters / labels / allocation units (see `defaults/main.yml`) |

`validate.yml` fails the play closed if the three disk ids or drive letters collide, or if
`license_key` / `service_account.name` are empty.

## Build status

Skeleton. The install spine is built one MS/PDQ-doc-grounded piece per cycle.
`present_windows.yml` is currently a no-op
that proves config merge + validation.

## Reference install spine (target)

App Share on G: (dir + SMB share + ACLs) → Background Service User → install PDQ Inventory (MSI
silent `Mode=Server ServerPort Licensekey /qn /norestart`) → install PDQ Deploy (same user + mode)
→ Central Server enable + firewall exception → relocate Inventory DB→F:, Deploy DB→E:, Deploy
repository→G: → verify services + Central Server port.
