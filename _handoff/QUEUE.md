# Build queue — pdq role (one command per cycle)

> **Draft sequence — refined with the Director before each cycle enters P0.** Each piece is the
> SMALLEST next best Ansible operation (≈ one module), grounded in the vendor-documented PDQ
> procedure. Decompose larger goals. After E2E validation write a judgement-decisions report,
> then STOP for approval before the next step (see `_handoff/RESTART.md`).

**Role contract:** handed a Windows Server 2025 machine = OS + SSH + **three attached BLANK data
disks** (RAW); the role configures it E2E into a PDQ Deploy & Inventory **all-in-one Central
Server**. Topology is fixed — both apps on one host, one Background Service User (integration
requires it).

**Reference install spine (vendor-doc-grounded):** provision data volumes (E: PDQDEPLOY / F:
PDQINVENTORY / G: PDQSHARE) → App Share on G: (dir + SMB share + ACLs) → Background Service User
(local admin, R/W share) → install PDQ Inventory (MSI silent `Mode=Server ServerPort Licensekey
/qn /norestart`) → install PDQ Deploy (same user + mode) → Central Server enable + firewall
exception (TCP 7337) → relocate Inventory DB→F:, Deploy DB→E: → point Deploy repository→G: →
link Deploy↔Inventory integration → verify.

> **P0 automation research COMPLETE (2026-07-27): `docs/reference/pdq-automation.md`.** Headless
> install is feasible — no GUI. Mechanisms per piece: **MSI silent** (install + license),
> **PDQ CLI** `SetServiceMode`/`SetServiceCredentials`/`Settings`/`ConsoleUsers`/`SystemInfo` (mode,
> service user, integration, verify), **registry** `HKLM\SOFTWARE\Admin Arsenal\PDQ <app>\Settings\Database\FileName`
> (DB location). Residual on-VM confirmations (do at the consuming piece's P0): exact CLI param
> syntax (`<app> Help <cmd>`), repository-path mechanism (P11), and the **WAL/`-shm`/`log.db`
> relocation caveat** (P09/P10 — the biggest open risk; only `Database.db` may move).

## Infra prerequisite (not a role cycle)

| ID | Task | Status |
|----|------|--------|
| P00 | Provision the PDQ dev VM + clean baseline snapshot (3 blank disks, static IP, SSH+PowerShell, VMware Tools); capture the 3 disks' `eui.*` ids into `pdq.yml`; update `revert-vm.sh` VMX/snapshot. See `docs/VM-LIFECYCLE.md §3`. | ✅ 574439c |

## Role build queue (draft)

| ID | Piece (single command / operation) | Status |
|----|-----------------------------------|--------|
| P01 | Skeleton wiring proof: `compose-and-run.sh` overlays `windows_disk_manager` + `pdq`, both loaders resolve, `pdq` present is a validated no-op. Green gate + a from-baseline converge (`changed=0` on the no-op). | ✅ |
| P02 | `windows_disk_manager`: declare the 3 PDQ disks; init/partition/format E:/F:/G: (`PDQDEPLOY`/`PDQINVENTORY`/`PDQSHARE`, NTFS 4 KiB). Reuses the merged windows-wsus disk arc — may be 1 cycle if the role is mature, else decompose init→partition→format. | ✅ (windows_disk_manager in framework, pin 1abfec4) |
| P03 | App Share directory on G: (`win_file` — e.g. `G:\PDQRepository`) + explicit ACLs: `BUILTIN\Users` R&X (inherit, org convention) + service account R/W. | ✅ 0c4c9a0 (bundled P04; explicit Admin/SYSTEM ACEs; G:\AppRepo) |
| P04 | SMB share for the repository (`win_share`) — the install-source UNC the Deploy repository points at; share + NTFS perms aligned to the service account + deploy users. | ✅ folded into P03 (Administrators-only SMB share) |
| P05 | Background Service User — create/validate the local account `svc-pdq` (`win_user`), add to local `Administrators`, ensure R/W to the App Share (Log-On-as-Service is auto-granted by PDQ). Applied to each app via CLI `SetServiceCredentials`. ONE account for both (integration prereq). `no_log`. | ✅ ad26a08 (pre-granted Log-On-as-Service; update_password=on_create) |
| P06 | Install **PDQ Inventory** — MSI silent from the **self-hosted pinned artifact** (checksum-gated `win_get_url`/S3 → `win_package`): `Mode=Server ServerPort=<port> Licensekey=<key> /qn /norestart` (case-sensitive props; license `no_log`). Idempotency via `SystemInfo`/`win_package` version. | ⛏️ ◀ NEXT |
| P07 | Install **PDQ Deploy** — same self-hosted MSI + silent pattern, SAME service user + `Mode=Server` (integration). | ⛏️ |
| P08 | Enable **Central Server** on both apps via CLI `SetServiceMode Server` + Windows Firewall exception (`win_firewall_rule`) for TCP `central_server.port` (7337). Idempotent: read current mode via `Settings`/`SystemInfo`, set on diff. | ⛏️ |
| P09 | Relocate **PDQ Inventory** database → F: via registry `HKLM\SOFTWARE\Admin Arsenal\PDQ Inventory\Settings\Database\FileName` (`win_regedit`): stop service → set → move DB dir → start. ⚠ **P0 must confirm on-VM whether `-wal`/`-shm`/`log.db` also relocate** (only `Database.db` may move — the biggest open risk). | ⛏️ |
| P10 | Relocate **PDQ Deploy** database → E: — same registry method under `…\PDQ Deploy\Settings\Database\FileName`; same on-VM caveat. | ⛏️ |
| P11 | Point the **PDQ Deploy repository** → G: App Share (UNC). Mechanism `Settings` CLI vs registry — **confirm on-VM at P0**. | ⛏️ |
| P12 | **Integration link** — same Background Service User + mode; cross-authorize via CLI `ConsoleUsers` if needed. Prove Deploy sees an Inventory collection (`GetCollectionComputers`). | ⛏️ |
| P13 | Verify (or DROP as theater if every check is an upstream fail-closed gate, per house rule): services running, Central Server port listening, integration live. | ⛏️ |

## Notes

- **Reuse over reinvent:** the 3-disk provisioning is `windows_disk_manager` (folded in from
  windows-wsus) — do NOT reimplement disk logic in the `pdq` role.
- **Secrets:** `license_key` and `service_account.password` are `no_log` everywhere; never
  committed, never printed. Supply via `-e`/vault.
- **Inline-PowerShell gate:** any `win_shell`/`win_command` free-form block must pass
  `scripts/check-winshell-splitargs.py` (use `[char]92`, no `\'`/`\"`).
- **AWS PoC layer:** deferred (Phase 2). Do not clone the wazuh AWS IAM until it is CLONE-READY
  (`../windows-wsus/_handoff/AWS-IAM-AUDIT-wazuh.md`).
