# pdq-deploy-inventory — READMAP (single ordered source of priority)

_Created 2026-07-27 by Claude. The forward-looking, what-remains view in priority order. Refreshed
at P5 of every successful cycle (house rule) — it must always describe `main`'s merged state. Does
NOT replace `_handoff/QUEUE.md` (piece detail), `_handoff/REVIEW.md` (audit ledger),
`_handoff/steps/` (plan packets + RTRACK), or `_handoff/RESTART.md` (read FIRST)._

Status legend: ✅ done · 🔄 in-flight · 📐 designed (ready) · 💤 deferred · ⛏️ not-started · ❓ director-decision-open

---

## 1. Recommended global order

1. **P00 — Provision the PDQ dev VM** (✅ 2026-07-27). `pdq-dev` full-cloned from the wsus clean
   baseline, MAC pinned → IP 192.168.0.181 (never run both VMs), booted SSH-ready, memory-baseline
   snapshot taken, scripts/inventory repointed, 3 disk `eui.*` ids captured into `pdq.yml`.
2. **P01 — Skeleton wiring proof** (✅ 2026-07-27). Live-VM E2E green: `ok=23 changed=0 failed=0`;
   both loaders resolve, `pdq` validate passes, present no-op. Harness proven before any PDQ logic.
3. **P02 — Disk provisioning** (framework work) — via `windows_disk_manager` in `ansible-framework`.
   **WDM-01 (guard-only scaffold) ✅ MERGED** to framework `main` `6cfda6b [audited 5fc1f62]`
   (2026-07-27): the role is now the canonical framework home (v3.2.0 loader, `platform` vmware|aws +
   `disks:[]` contract, state-scoped validate guards, fail-closed present). Ran the full app-repo
   strict cycle (P2 Codex AGREE r5 → P3 → P4 live-VM proof matrix on `pdq-dev`, 2 defects repaired →
   P4.5 approved), system codex `gpt-5.6-sol`. **WDM-02a ✅ MERGED** `197c5ca [audited 4111693]`
   (superseded). **WDM-02b ✅ MERGED** `1abfec4 [audited 73048d8]` (2026-07-27): **the role now fully
   provisions.** Director rip-out-classifier decision ("config control is the operator's job; don't
   handhold") replaced the elaborate 02a classifier with a MINIMAL trust-config pipeline — resolve →
   online → skip-if-ours (NTFS+label via `partitions[].volumes[]`, idempotency only) → `win_initialize_disk`
   → `win_partition` → `win_format`, `force:false`, NTFS-only. **Live-proven on pdq-dev: formatted
   E:PDQDEPLOY/F:PDQINVENTORY/G:PDQSHARE NTFS (changed=3), idempotency re-run changed=0.** Fixed a latent
   02a traversal bug. **`windows_disk_manager` is now a complete framework disk-provisioning role.**
   **pdq repoint ✅ DONE** `f979ad4` (2026-07-27): `.framework-pin` → `1abfec4`, local stopgap dropped,
   `disks:[]` wired into `pdq.yml`. **Live-proven: compose framework windows_disk_manager → E:PDQDEPLOY /
   F:PDQINVENTORY / G:PDQSHARE NTFS (changed=3), pdq validate+no-op, ok=36 failed=0.** **P02 disk
   provisioning COMPLETE.** ⚠ **Open: the framework commits (WDM-01/02a/02b, pin 1abfec4) are LOCAL-ONLY
   — not pushed to GitHub; CI / any non-local consumer needs them pushed (Director decision).**
   **NEXT: the PDQ install spine — QUEUE P03+** (App Share on G: → service account → MSI installs →
   Central Server → DB relocation → integration). The pdq role's transitional `deploy_disk_id`/etc. get
   removed when it's reshaped to consume drive letters (a pdq-role cycle).
4. **P03 App Share ✅ MERGED** `0c4c9a0 [audited 66e97bb]` (2026-07-27): `G:\AppRepo` dir + 3 explicit
   NTFS ACEs (Users R&X, Administrators/SYSTEM Full) + Administrators-only SMB share, live-proven
   (changed=8, idempotent; falsifiable ACL/share assertions verified). Push default; Pull-copy + PDQ
   inheritance-hardening deferred. **P05 Background Service User ✅ MERGED** `ad26a08 [audited 0509401]`
   (2026-07-28): local `svc-pdq` via `win_user` (no_log password, Administrators via groups_action=add,
   password_never_expires, user_cannot_change_password, update_password=on_create) + `win_user_right
   SeServiceLogonRight` (`.\svc-pdq`), inserted BEFORE the App Share region. Repository R/W via
   Administrators membership (P03's Admin-Full ACE) — no per-account ACE. **Live-proven on pdq-dev:**
   create changed=10 failed=0 (Enabled, PasswordExpires=never, UserMayChange=False, in Administrators,
   SeServiceLogonRight granted); SKIP_REVERT idempotency changed=0; default-verbosity secret hygiene 0
   leaks. **Finding TD-005:** the v3 loader echoes the merged `pdq_running` (incl. the service password)
   at `-v` — framework governance surface; fix via loader-change-protocol (`no_log` the loader set_fact);
   default runs clean, does NOT block. One service user for both apps. **NEXT: P06/P07 MSI installs.**
5. **P06–P08 — Install both apps + Central Server + firewall** (⛏️). PDQ alive. **P06 next:** PDQ
   Inventory — self-hosted pinned MSI (checksum-gated), silent `Mode=Server ServerPort Licensekey /qn
   /norestart` (license `no_log`); then P07 Deploy (SAME service user + `Mode=Server`).
6. **P09–P12 — DB relocation + repository + integration** (⛏️). The whole point: integrated AIO on
   the 3 disks.
7. **P13 — Verify / END** (⛏️ or DROP).

## 2. Locked decisions ledger

- **Composition, not vendoring** — the role overlays into a `.framework-pin`ned ansible-framework
  checkout; never runs repo-side.
- **v3 loader untouchable** — byte-identical `tasks/main.yml`; any change (even a recommendation)
  goes through the Fable+Sol `loader-change-protocol.md` gate + Director acceptance.
- **Transport = SSH** (`ansible_shell_type: powershell`), **`become: false`** play-level.
- **Fixed topology (vendor-doc-grounded):** PDQ Deploy + Inventory on ONE host, Central Server
  mode, ONE Background Service User — the only configuration in which they integrate. Split
  servers = standalone, no integration. This is a design invariant, not a tunable.
- **3-disk layout:** E: `PDQDEPLOY` (Deploy DB) / F: `PDQINVENTORY` (Inventory DB) / G: `PDQSHARE`
  (Deploy repository/App Share); NTFS 4 KiB (SQLite DBs, no SQL-engine cluster-size best practice
  to inherit — contrast WSUS's 64 KiB SUSDB).
- **`windows_disk_manager` mirrors `linux_disk_manager`'s contract** (Director, 2026-07-27):
  `platform` (vmware|proxmox|aws) + a **`disks: []` list**, each entry declaring `unique_id` OR
  `function` (+ `drive_letter`, `label`, `allocation_unit`, `fstype`). VMware/Proxmox require a
  **manual `unique_id`** list (no seamless authored-identity mechanism exists there); AWS uses the
  EBS `function` tag resolved at run time (the `resolve_aws` path) — exactly `linux_disk_manager`'s
  split. Reshapes the pdq playbook (and later wsus) to pass disks as a list; the consuming role then
  keys off `drive_letter`, not disk ids.
- **`windows_disk_manager`'s home is `ansible-framework/applications/windows_disk_manager`**
  (Director, 2026-07-27) — the Windows sibling of the framework's existing `linux_disk_manager`, NOT
  a per-repo role. App repos (pdq, wsus, future) **compose** it from the framework; none carry a
  copy. The `pdq` role does no disk logic itself. **Current stopgap:** pdq carries a LOCAL
  `ansible/applications/windows_disk_manager` (copied from wsus) only because the framework does not
  ship it yet AND pdq's `.framework-pin` (`6fde6f9`) predates even `linux_disk_manager`. To remove:
  promote windows_disk_manager into the framework → bump `.framework-pin` → delete the local copy.
- **Director reviews the changed role file before every merge (P4.5)**, in the locked format.
- **Smallest vendor-doc-grounded steps**, one command per cycle, revert-first.

## 3. Director-decision queue (researched 2026-07-27 → recommendations; Director to confirm)

Full grounding + citations: `docs/reference/pdq-automation.md`. **Headless install confirmed
feasible** — MSI silent + PDQ CLI (`SetServiceMode`/`SetServiceCredentials`/`Settings`/`ConsoleUsers`)
+ registry (DB location) + `win_*`. No GUI needed.

- 📐 **PDQ MSI source → PIN + self-host in the artifact bucket** (wazuh pattern). PDQ downloads are
  form-gated (no static versioned URL); staging pinned MSIs in `<account-id>-ansible/applications/pdq/…`
  with a checksum gate gives reproducible/offline/pinnable installs. Affects P06/P07.
- 📐 **Service account → role-created LOCAL `svc-pdq`** for the Background Service User (self-contained
  AIO; local admin + Log-On-as-Service + share R/W all work locally; overridable to domain). Target/scan
  credentials to reach managed clients are a SEPARATE later concern, not the service user. Affects P05.
- 📐 **License → `-e`/vault at runtime**, applied via the MSI `Licensekey=` property (`no_log`); never
  committed. Affects P06/P07.
- 📐 **DB relocation → registry `HKLM\SOFTWARE\Admin Arsenal\PDQ <app>\Settings\Database\FileName`**
  (stop service → set → move → start). ⚠ **On-VM confirmation required at P09/P10**: community
  guidance says only `Database.db` relocates while `-wal`/`-shm`/`log.db` stay in `%ProgramData%` —
  the single biggest open technical risk. Confirm before trusting the relocation.

## 4. Deferred / parking lot

- 💤 **AWS PoC layer** (terraform + `.github/workflows/{deploy,e2e-full}` + IAM). Phase 2. Clone
  from `secure-wazuh` ONLY after that repo's IAM is CLONE-READY (Round 2 today = CLONE-WITH-FIXES;
  see `../windows-wsus/_handoff/AWS-IAM-AUDIT-wazuh.md`). Re-derive per-repo identity; do not copy
  the `<account-id>`-in-Deny pattern or committed VPC/SG/subnet literals.
- 💤 **GitHub repo import** (`nwarila-platform` org) + release-please + mkdocs site + CI workflows.
  After the role is operational on VMware.
- 💤 **Backport to a `*-template` repo** once fully operational.

## 5. Session handoff (2026-07-28)

Install spine underway. **Merged to `main`:** P00 dev VM, P01 wiring, P02 disk provisioning
(`windows_disk_manager` in the framework + repoint), P03 App Share on G:, **P05 Background Service
User (`ad26a08`)**. The role now: provisions E:/F:/G: NTFS, builds the `G:\AppRepo` dir + SMB share,
and creates the shared local `svc-pdq` service account (Administrators + Log-On-as-Service). **Still no
PDQ software installed.** **NEXT: P06** — install PDQ Inventory (self-hosted pinned MSI, checksum-gated,
silent `Mode=Server ServerPort Licensekey /qn /norestart`), then P07 Deploy (same service user + mode).

**Open governance item — TD-005:** the v3 loader prints the merged config (incl. secrets) at `-v`.
Queued for the `loader-change-protocol` (one Fable + one Codex-Sol validator, then Director acceptance)
— Claude to run that gate when the Director directs; default-verbosity runs are clean meanwhile.

**Framework PR #39** (`windows_disk_manager`) still awaits the Director's GitHub merge; the framework
commits (pin `1abfec4`) are LOCAL-ONLY. If the PR squashes on merge, re-pin pdq's `.framework-pin` to
the squashed SHA. Confirm the §3 open decisions with the Director before the pieces that consume them.
