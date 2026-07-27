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

> **Per-piece research is mandatory at P0** (PDQ Help Center + MSI property docs). PDQ's
> DB-relocation and Central-Server mechanics are less MS-canonical than WSUS's — confirm the exact
> supported procedure (config file, service stop/start, registry, or console CLI) before writing
> each relocation/config piece.

## Infra prerequisite (not a role cycle)

| ID | Task | Status |
|----|------|--------|
| P00 | Provision the PDQ dev VM + clean baseline snapshot (3 blank disks, static IP, SSH+PowerShell, VMware Tools); capture the 3 disks' `eui.*` ids into `pdq.yml`; update `revert-vm.sh` VMX/snapshot. See `docs/VM-LIFECYCLE.md §3`. | ⛏️ not-started |

## Role build queue (draft)

| ID | Piece (single command / operation) | Status |
|----|-----------------------------------|--------|
| P01 | Skeleton wiring proof: `compose-and-run.sh` overlays `windows_disk_manager` + `pdq`, both loaders resolve, `pdq` present is a validated no-op. Green gate + a from-baseline converge (`changed=0` on the no-op). | ⛏️ |
| P02 | `windows_disk_manager`: declare the 3 PDQ disks; init/partition/format E:/F:/G: (`PDQDEPLOY`/`PDQINVENTORY`/`PDQSHARE`, NTFS 4 KiB). Reuses the merged windows-wsus disk arc — may be 1 cycle if the role is mature, else decompose init→partition→format. | ⛏️ |
| P03 | App Share directory on G: (`win_file` — e.g. `G:\PDQRepository`) + explicit ACLs: `BUILTIN\Users` R&X (inherit, org convention) + service account R/W. | ⛏️ |
| P04 | SMB share for the repository (`win_share`) — the install-source UNC the Deploy repository points at; share + NTFS perms aligned to the service account + deploy users. | ⛏️ |
| P05 | Background Service User — create/validate the local account (`win_user`), add to local `Administrators`, ensure R/W to the App Share. ONE account for both apps. `no_log` password. | ⛏️ |
| P06 | Download + install **PDQ Inventory** (MSI silent: `Mode=Server ServerPort=<port> Licensekey=<key> /qn /norestart`). `win_get_url` + `win_package`; license `no_log`. Research: current MSI URL + property set. | ⛏️ |
| P07 | Download + install **PDQ Deploy** (MSI silent, SAME service user + operating mode for integration). | ⛏️ |
| P08 | Enable **Central Server** mode on both apps + Windows Firewall exception (`win_firewall_rule`) for TCP `central_server.port` (7337). Research: supported enable mechanism (console CLI / config / service). | ⛏️ |
| P09 | Relocate **PDQ Inventory** database → F: (`PDQINVENTORY`). Research the PDQ-supported move procedure (stop service → move DB → repoint → start). | ⛏️ |
| P10 | Relocate **PDQ Deploy** database → E: (`PDQDEPLOY`), same supported procedure. | ⛏️ |
| P11 | Point the **PDQ Deploy repository** → G: App Share (UNC). | ⛏️ |
| P12 | **Integration link** — confirm Deploy↔Inventory integration (shared Background Service User / cross-added console user; same mode). Prove Deploy can see an Inventory collection. | ⛏️ |
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
