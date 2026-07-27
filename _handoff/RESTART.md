# RESTART.md — the single re-entry document (any agent, any point)

> Read this FIRST. Everything an agent needs that is NOT derivable from the repo lives here. If you
> learn something durable, add it HERE. Then read `READMAP.md` (current position) and
> `_handoff/QUEUE.md` (what's next). This repo was scaffolded 2026-07-27 by mirroring
> `secure-wazuh` (structure) with `windows-wsus` (Windows lessons) folded in.

## 1. Who reads what

| Reader | Instruction file | Role |
|---|---|---|
| **Claude** | `.claude/CLAUDE.md` (includes `AGENTS.md`) | Plan (P0), Director liaison (P1), drive Codex, validate (P4), merge + codify (P5) |
| **Codex** | `AGENTS.md` only | Adversarial plan review (P2), execution (P3). Never plans, never merges |
| **Director** | everything | Final authority. Consulted EVERY piece. Ratifies style rules |

Cycle: `_handoff/loop/STRICT-CYCLE-adapted.md`. One command = one piece = one cycle.

## 2. Mission

A single-purpose `nwarila-platform` application repo carrying the **`pdq`** role — a **PDQ Deploy &
Inventory all-in-one Central Server** on Windows Server 2025 — plus its playbook and inventory. It
**composes** into a version-pinned `nwarila-platform/ansible-framework` checkout at execution time.
It reuses **`windows_disk_manager`** (folded in from windows-wsus) for the 3-disk provisioning.
Backport to a `*-template` repo once operational. `terraform/` is a skeleton, **NOT ACTIVE**.

## 3. Non-negotiable constraints

- **Revert the VM before EVERY playbook execution** (`scripts/revert-vm.sh`; built into
  `compose-and-run.sh`; `SKIP_REVERT=1` = composition testing only).
- **One command per cycle.** Split a piece that grows a second command.
- **`tasks/main.yml` (v3 loader) is untouchable per-role.** Any change — even a recommendation —
  goes through `_handoff/loop/loader-change-protocol.md` (one independent Claude/Fable + one
  Codex 5.6/Sol validator, then Director accepts). Claude orchestrates, never validates.
- **Style-guide changes are proposals until the Director ratifies them** (`docs/ansible-style-guide.md`).
- **Director reviews the changed role file before every merge (P4.5)**, surfaced UNSTAGED in
  Source Control → Changes, in the locked format (see the style/cycle docs).
- **Smallest vendor-doc-grounded steps** — each piece is the smallest next PDQ operation, grounded
  in the PDQ Help Center / MSI docs.
- **`READMAP.md` refreshed in the same P5 codification commit, every cycle.**
- Never print secrets (license key, service-account password) into the transcript; never commit them.

## 4. Environment

**Dev VM — PROVISIONED 2026-07-27 (P00).** `pdq-dev` at `D:\Documents\Virtual Machines\pdq-dev\pdq-dev.vmx`
— a full clone of the windows-wsus `pre-ansible-clean-ssh-ready` snapshot (clean Windows Server 2025,
OpenSSH `DefaultShell=PowerShell`, VMware Tools, **3 blank data disks**). Its MAC is pinned static
(`00:0C:29:98:E2:69`, `uuid.action=keep`) so it reuses the wsus static IP **192.168.0.181** — therefore
the wsus and pdq dev VMs **MUST NOT run simultaneously** (same discipline as `adopt-lab-vmx.py`). Clean
memory-baseline snapshot `pre-ansible-clean-ssh-ready` taken (running → revert resumes instantly).
Inventory + `revert-vm.sh`/`snapshot-step.sh` are repointed. **Remaining (key-gated):** capture the 3
data disks' `Get-Disk` UniqueId (`eui.*`) into `ansible/playbooks/pdq.yml` (`deploy/inventory/share_disk_id`)
— a full clone re-mints all `eui.*`, so the wsus ids do NOT carry over; capture on the live VM. The 3
disks are still WSUS-named vmdks (blank; the role relabels at format) — cosmetic, optionally renamed later.

**Controller** — WSL Ubuntu 24.04. pipx: `ansible-core 2.21.2`, `ansible-lint`, `yamllint` at
`/root/.local/bin/`. Collections `ansible.windows`, `community.windows` (user scope). Transport is
**SSH, not WinRM**: `ansible_shell_type: powershell`, `become: false`. `vmrun` at
`/mnt/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe`.

**SSH keys — the #1 false alarm.** The agent empties on every controller reboot. `ssh-add -l` must
list the server-access key + the git-signing key. If either is missing, hand the Director
`docs/KEY-RELOAD.md`. Empty agent → `Permission denied (publickey)`; `No route to host` → VM off.

**Codex** — isolated per-project home once wired (mirror windows-wsus `docs/CODEX-SESSION.md`).
`< /dev/null` is MANDATORY on every non-interactive `codex exec` (drains stdin). A genuinely
hanging call is almost always a revoked token; probe ONCE. Codex's sandbox cannot commit — Claude
commits on its behalf.

## 5. The cycle + the gate

P0 plan (`_handoff/steps/<piece>.plan.json`) → P1 Director consult (no auto-approve) → P2 Codex
adversarial review (verdict line 1: AGREE/REVISE/REFUSE) → P3 Codex executes in `../.worktrees/<piece>`
allowlist-only → P4 Claude validates diff vs packet, style, gate, proofs → P4.5 Director → P5 merge
`--no-ff` `[audited <sha>]` + `_handoff/REVIEW.md` row + `RTRACK-<piece>.md` + `READMAP.md` refresh.

```bash
export PATH="$PATH:/root/.local/bin"
yamllint -c .yamllint.yml ansible
(cd .compose/ansible-framework && ansible-lint applications/windows_disk_manager applications/pdq)
bash -n scripts/compose-and-run.sh scripts/revert-vm.sh
/root/.local/share/pipx/venvs/ansible-core/bin/python scripts/check-winshell-splitargs.py
```

`check-winshell-splitargs.py` is the ONLY static gate catching `\'` in `win_shell`/`win_command`
free-form (yamllint, ansible-lint, `--syntax-check` all miss it). Use `[char]92`. It does NOT apply
to `win_powershell`. Glob is non-recursive — task files sit directly under `tasks/`.

`compose-and-run.sh` takes `COMPOSE_PLAYBOOK=` (default `pdq.yml`) and overlays every role under
`ansible/applications/`.

## 6. PDQ facts (vendor-doc-grounded; expand as pieces land)

- **Fixed topology.** PDQ Deploy + Inventory integrate ONLY when co-located, same operating mode
  (Central Server), under ONE Background Service User (or each cross-added as a console user in the
  other). On separate hosts they are standalone and do not interface. → single AIO host, one
  service account. ([PDQ Integration](https://help.pdq.com/hc/en-us/articles/4409527534747-Integration-Between-PDQ-Deploy-and-PDQ-Inventory))
- **Central Server** = one server console managing the D&I databases + repository + background
  service; client consoles connect (default **TCP 7337**, configurable; needs a firewall exception).
  Enterprise license required. ([Central Server](https://www.pdq.com/blog/central-server/))
- **Background Service User** = local admin on the PDQ server, R/W to the repository; domain or
  local. ([Credentials](https://help.pdq.com/hc/en-us/articles/115002510472-PDQ-Deploy-Inventory-Credentials-Explained))
- **Silent install** = MSI `Mode=Server|Client Servername ServerPort Licensekey /qn /norestart`.
  ([Getting Started](https://help.pdq.com/hc/en-us/articles/360058253252-Getting-Started-With-PDQ-Deploy-Inventory))
- **Databases** are SQLite (not a SQL engine) → NTFS 4 KiB is correct; no 64 KiB SQL best practice
  to inherit. DB relocation procedure is less canonical than WSUS's — **research per-piece at P0**.
- **Lessons inherited from windows-wsus** (see that repo's RESTART §6 for the Windows/Ansible traps:
  disk identity by NTFS label, `win_partition`/`win_format` gotchas, PS 5.1 JSON quirks,
  `win_powershell` check-mode resolver rule, loader override-dict replacement, TD-001/002/003).

## 7. Platform model

| Platform | Role | Lifecycle |
|---|---|---|
| **Proxmox** | Production | lives forever (DEFERRED behind other work) |
| **AWS** | Ephemeral E2E PoC in CI + portfolio artifact | deploy → check → destroy (Phase 2) |
| **VMware** | Local dev loop | the proving ground (Phase 1 — CURRENT) |

Order: **PHASE 1 VMware (now)** → PHASE 2 AWS (clone wazuh's hardened IAM only once CLONE-READY) →
PHASE 3 GitHub workflows. Select disks by what the pipeline AUTHORS (NTFS label / authored identity),
never what it DISCOVERS.

## 8. Standing guidance

- **Don't over-engineer.** Fix detection, don't add declaration layers. Prefer shipping a small
  correct piece over another round of review. Use the question tool for genuine decisions, with a
  recommendation attached.
- **Reuse over reinvent** — `windows_disk_manager` owns disks; the `pdq` role does not duplicate it.

## 9. Deriving current position

1. `git log --oneline -15` — last `merge(pdq): … [audited <sha>]` = last completed piece.
2. `READMAP.md` §5 handoff — describes `main`'s merged state.
3. `_handoff/QUEUE.md` — next queued piece (currently **P00: provision the dev VM**).
4. `_handoff/REVIEW.md` — one row per completed cycle.
5. `_handoff/steps/RTRACK-*.md` — what actually happened.
6. Confirm the next piece with the Director before starting.

## 10. Session-start checklist

1. `ssh-add -l` lists both keys (§4).
2. The PDQ dev VM exists + is reachable (once P00 is done) — else the next task IS P00.
3. `vmrun -T ws listSnapshots <vmx>` → baseline + at most one rolling snapshot.
4. Codex authed (once wired) — `codex doctor` → `✓ auth`.
5. Derive position (§9), then confirm the next piece with the Director.
