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
3. **P02 — Disk provisioning** (⛏️ NEXT) — E:/F:/G:. **Design open:** `windows_disk_manager`
   present is still only a platform guard (its disk-mutation pieces are the windows-wsus C15 arc,
   in progress) — decide whether pdq waits on WDM maturing or the `pdq` role owns disk init like
   wsus did. See §3.
4. **P03–P05 — App Share + service account** (⛏️). The integration substrate (one service user).
5. **P06–P08 — Install both apps + Central Server + firewall** (⛏️). PDQ alive.
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
- **Reuse `windows_disk_manager`** for disk provisioning (folded in from windows-wsus) — the `pdq`
  role does no disk logic itself.
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

## 5. Session handoff (2026-07-27)

Skeleton scaffolded: mirrors `secure-wazuh` structure + `windows-wsus` Windows lessons. Role
loader/defaults/validate/present-stub in place, `windows_disk_manager` reused, `pdq.yml` play,
dev inventory, compose + gate scripts, strict-cycle docs, this queue. **Nothing PDQ is installed
yet.** Next action: P00 (provision the dev VM) — everything else blocks on it. Confirm the §3
open decisions with the Director before the pieces that consume them.
