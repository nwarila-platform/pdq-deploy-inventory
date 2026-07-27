# pdq-deploy-inventory — READMAP (single ordered source of priority)

_Created 2026-07-27 by Claude. The forward-looking, what-remains view in priority order. Refreshed
at P5 of every successful cycle (house rule) — it must always describe `main`'s merged state. Does
NOT replace `_handoff/QUEUE.md` (piece detail), `_handoff/REVIEW.md` (audit ledger),
`_handoff/steps/` (plan packets + RTRACK), or `_handoff/RESTART.md` (read FIRST)._

Status legend: ✅ done · 🔄 in-flight · 📐 designed (ready) · 💤 deferred · ⛏️ not-started · ❓ director-decision-open

---

## 1. Recommended global order

1. **P00 — Provision the PDQ dev VM + baseline** (⛏️ not-started). Blocks everything: no VM = no
   E2E. 3 blank disks, static IP, SSH+PowerShell, VMware Tools, clean snapshot; capture disk
   `eui.*` ids; repoint `revert-vm.sh`/`snapshot-step.sh`/inventory off the windows-wsus placeholders.
2. **P01 — Skeleton wiring proof** (⛏️). Compose green, both loaders resolve, `pdq` present no-op
   converges `changed=0`. First merge — proves the harness before any PDQ logic.
3. **P02 — Disk provisioning** (⛏️) via `windows_disk_manager` (reused). E:/F:/G:.
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

## 3. Director-decision queue (open)

- ❓ **PDQ MSI source** — pin specific MSI versions/URLs, or always latest? (Affects P06/P07 +
  idempotency + reproducibility.)
- ❓ **Service account** — role-created **local** account (simple, self-contained) vs an
  operator-supplied **domain** account (production-realistic). Skeleton assumes local `svc-pdq`.
- ❓ **License delivery** — `-e`/vault at run time vs a committed encrypted vault file.
- ❓ **DB relocation mechanism** — needs P0 research; PDQ's supported move procedure is not as
  canonical as WSUS's. Confirm before P09/P10.

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
