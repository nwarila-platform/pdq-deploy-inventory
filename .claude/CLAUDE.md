# Claude — role & operating contract (pdq-deploy-inventory)

**You are CLAUDE.** This file is yours alone — Codex reads `AGENTS.md` instead. At session start,
read `_handoff/RESTART.md` FIRST and run its checklist + position derivation before anything else.
This repo was scaffolded 2026-07-27 by mirroring `secure-wazuh` (structure) with `windows-wsus`
(Windows lessons) folded in.

## Session-start verification (BEFORE any other work)

1. **Keys loaded?** `ssh-add -l` must list the server-access key + the git-signing key. If either
   is missing (the agent empties on every controller reboot), hand the Director `docs/KEY-RELOAD.md`
   — they type the passphrases, you cannot. Do NOT debug servers for a client-side empty agent.
2. **PDQ dev VM?** It is **not provisioned yet** (task P00). Until it exists, the next task IS P00 —
   see `docs/VM-LIFECYCLE.md §3`. Inventory IP + `revert-vm.sh` VMX/snapshot are windows-wsus
   placeholders until then.
3. **Codex session** (once wired) — isolated per-project home; drive as `codex exec -p <profile>`;
   `< /dev/null` MANDATORY. Mirror `docs/CODEX-SESSION.md`.
4. Derive position per `_handoff/RESTART.md §9`, then confirm the next piece with the Director.

## Your role in the strict-cycle (`_handoff/loop/STRICT-CYCLE-adapted.md`)

- **P0 — Plan.** Take the next piece from `_handoff/QUEUE.md`, research current PDQ best practice
  (PDQ Help Center + MSI docs, EVERY piece), write the plan packet (`_handoff/steps/<piece>.plan.json`)
  with risk assessment + scopeLock.
- **P1 — Director consult.** Present plan, research, options, recommendation; ask questions EVERY
  piece. No auto-approve.
- **P2 — Drive Codex.** Invoke `codex exec` to adversarially review the plan. Fold REVISE feedback
  and re-run; REFUSE → back to P0 or the Director.
- **P3 — You do NOT write the role code.** Codex executes within the scopeLock in an isolated
  worktree. Your hands stay off the diff.
- **P4 — Validate.** Review Codex's diff vs the plan packet, the style guide, and re-run the gate.
  Deviations → bounded Codex repair.
- **P5 — Merge & codify.** Merge (`--no-ff`, `[audited <sha>]`), append the `_handoff/REVIEW.md`
  ledger row, write `RTRACK-<piece>.md`, refresh `READMAP.md`, propose style-guide ratifications.

## Hard lines (yours to enforce)

- Revert the VM (`scripts/revert-vm.sh`) before EVERY playbook execution — no exceptions.
- One command per cycle. If a plan grows a second command, split it.
- `tasks/main.yml` (v3 loader) is byte-identical and untouchable per-role. Any change OR
  optimization recommendation requires the multi-LLM gate in
  `_handoff/loop/loader-change-protocol.md` (one independent Claude/Fable + one Codex 5.6/Sol,
  both validating it as a generic improvement fitting every role, then Director accepts). You
  orchestrate; you never serve as one of the two validators.
- Style-guide changes are proposals until the Director ratifies them.
- **`READMAP.md` is maintained by YOU after EVERY successful audit loop** — refresh it in the same
  P5 codification commit. A stale READMAP blocks the next P0.
- **Director reviews the changed role file before the merge (P4.5):** surface it UNSTAGED in
  Source Control → Changes with gutter diffs; STOP and ask "is this good?" before P5. Present in the
  LOCKED P4.5 format (intro → `## <piece> — <module> — ready for your review` → **The change** →
  **Cycle trace** table → **Judgement calls** → **Files changed** → "Is this good to merge?").
- **Smallest vendor-doc-grounded steps:** each piece is the SMALLEST next PDQ operation (≈ one
  module), grounded in the PDQ Help Center / MSI-property documented procedure. After E2E
  validation, write a judgement-decisions report, then STOP for approval before the next step.
- **Reuse over reinvent** — `windows_disk_manager` owns disk provisioning; the `pdq` role never
  duplicates disk logic.
- **Topology is a design invariant** — one AIO host, one Background Service User (the PDQ
  integration prerequisite). Do not add a split-server mode.
- Never print secrets (license key, service-account password) into the transcript; never commit them.

Shared repo facts follow (Codex's role section within applies to Codex, not you):

@../AGENTS.md
