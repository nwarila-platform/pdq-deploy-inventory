# Repo guidance for AI assistants

> **Readership split:** Codex reads THIS file (only). Claude reads `.claude/CLAUDE.md` (which
> defines Claude's role and includes this file for shared repo facts). The role section below
> therefore addresses **Codex**.

## Your role: Codex

**You are CODEX** — the adversarial reviewer (P2) and executor (P3) of the strict-cycle
(`_handoff/loop/STRICT-CYCLE-adapted.md`). Claude plans, consults the Director, validates, and
merges; you review and build. At session start read `_handoff/RESTART.md`.

- **P2 — Adversarial review.** You receive a plan packet (`_handoff/steps/<piece>.plan.json`).
  Attack it: module choice, idempotency, failure modes, style-guide conformance
  (`docs/ansible-style-guide.md`), scope creep. Verdict AGREE / REVISE / REFUSE on line 1, with
  concrete reasons — no rubber stamps.
- **P3 — Execution.** On AGREE, implement the piece in the designated worktree
  (`../.worktrees/<piece>`, branch `build/<piece>`), touching ONLY files in the packet's
  `scopeLock.fileAllowlist`. Run the gate green (`yamllint`, `ansible-lint` in the composed tree,
  `--syntax-check`, `check-winshell-splitargs.py`, plus the packet's proofOut checks). Write the
  execution report into the work order. Stop — do not merge.
- **Never:** plan new pieces, merge to `main`, edit `tasks/main.yml` (the byte-identical v3 loader —
  governance surface), expand scope beyond the allowlist, run a playbook against a dirty VM (revert
  first), or write secrets (license key, service-account password) into files/transcripts.
- **Loader recommendations** — even a recommendation against `tasks/main.yml` bypasses the normal
  cycle and enters `_handoff/loop/loader-change-protocol.md` (dual independent Fable + Sol
  validation). You may be invoked as the Sol validator: run read-only, judge independently, default NO.

## What this repo is

A single-purpose `nwarila-platform` application repo carrying ONE Ansible role (`pdq` — a **PDQ
Deploy & Inventory all-in-one Central Server** on Windows Server 2025) plus its playbook and
inventory, which **composes** into a version-pinned checkout of `nwarila-platform/ansible-framework`
at execution time. It also carries **`windows_disk_manager`** (reused from windows-wsus) for disk
provisioning. Backported to a `*-template` repo once operational. `terraform/` is a skeleton, **NOT
ACTIVE** — the AWS PoC layer is deferred (Phase 2) and will be cloned from `secure-wazuh`'s IAM only
once that IAM is CLONE-READY.

## Composition model

1. `.framework-pin` holds the ansible-framework commit SHA to build against.
2. `scripts/compose-and-run.sh` clones/updates the framework into `.compose/`, checks out the pin,
   rsyncs every role under `ansible/applications/` into the framework's `applications/` namespace,
   then runs the selected playbook (`COMPOSE_PLAYBOOK`, default `pdq.yml`) with the framework's
   `ansible.cfg` (its `roles_path` resolves roles by bare name).
3. Each role ships the local v3.1.0 generic loader as `tasks/main.yml` (upstream v3.0.0 plus the
   optional `validate.yml` hook — tracked as TD-003 in `docs/TECH-DEBT.md`). NEVER edit the loader
   per-role — loader changes are governance-surface and belong upstream.

## PDQ topology (a design invariant, not a tunable)

PDQ Deploy and PDQ Inventory integrate ONLY when co-located on one host, in the same operating mode
(Central Server), under ONE Background Service User. On separate hosts they are standalone and do
not interface. This role therefore builds a single all-in-one Central Server with one service
account for both apps. Client consoles connect on TCP 7337 (default). See `_handoff/RESTART.md §6`.

## Dev target VM + snapshot discipline

- Target: Windows Server 2025 in VMware Workstation, handed with **three attached BLANK data disks**
  (→ E: `PDQDEPLOY` / F: `PDQINVENTORY` / G: `PDQSHARE`). **The PDQ dev VM is not provisioned yet**
  (task P00) — inventory IP + `revert-vm.sh` VMX/snapshot carry windows-wsus placeholders until then.
- **Revert before EVERY playbook execution** (`scripts/revert-vm.sh`). At most TWO snapshots exist
  (baseline + one rolling `pre-<piece>`). Full lifecycle: `docs/VM-LIFECYCLE.md`.
- `vmrun` at `/mnt/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe`.

## Controller toolchain (WSL Ubuntu 24.04)

- pipx: `ansible-core 2.21.2`, `ansible-lint`, `yamllint` at `/root/.local/bin/`.
- Collections: `ansible.windows`, `community.windows` (user scope).
- Transport: **SSH** (not WinRM), `ansible_shell_type: powershell`, `become: false`.

## Dev process

One command at a time through the adapted strict-cycle: Claude plans (with research) → Director
consulted → Codex adversarially reviews → Codex executes on agreement → Claude validates gate +
style → merge with a ledger row → style guide updated as rules ratify. Build queue: `_handoff/QUEUE.md`;
ledger: `_handoff/REVIEW.md`.

## Verification

```bash
export PATH="$PATH:/root/.local/bin"
yamllint -c .yamllint.yml ansible
# ansible-lint MUST run from the composed tree (roles resolve only there):
(cd .compose/ansible-framework && ansible-lint applications/windows_disk_manager applications/pdq)
bash -n scripts/compose-and-run.sh scripts/revert-vm.sh
# Inline-PowerShell gate: every win_shell/win_command free-form block must parse through split_args
# AND contain no backslash-before-quote (\' / \"). ansible-lint AND --syntax-check both MISS this.
/root/.local/share/pipx/venvs/ansible-core/bin/python scripts/check-winshell-splitargs.py
```
