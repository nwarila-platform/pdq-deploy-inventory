# STRICT-CYCLE-adapted (windows-wsus edition) — build mode

One build command = one "piece". Never batch. Re-enter P0 after each merge.
Derived from the wazuh repo's adapted strict-cycle; division of labor per Director
(2026-07-15): **Claude plans & validates, Codex reviews & executes.**

## P0 — Plan (Claude)
- Take the next piece from `../QUEUE.md` (build command Cxx), research current
  best practice (web + module docs) for the specific command.
- **Smallest MS-doc step (Director 2026-07-15):** the piece is the SMALLEST next best
  Ansible operation (≈ one module), grounded in the Microsoft-documented procedure.
  Decompose larger goals into per-module steps (C02 → C02a–e). **Do NOT pre-approve the
  step** — build it and surface it at P4.5 (Director 2026-07-16: "you only stop after you
  have made the change for me to review"). Interrupt earlier only for a genuine design
  fork with no clear default.
- Emit a plan packet to `../steps/Cxx.plan.json`: goal, exact task(s) to add,
  module choice + alternatives considered, riskAssessment { blastRadius,
  rollbackFeasibility, selfSeveringCheck, proofOut{presence, absence} },
  scopeLock.fileAllowlist, style-guide deltas proposed.
- A piece whose fix would change any `tasks/main.yml` (byte-identical loader) — or
  even a mere recommendation/optimization proposal against it — is governance-surface
  → it does NOT use this cycle; it enters `loader-change-protocol.md` (the multi-LLM
  Fable + Sol generic-preservation gate + Director acceptance; default outcome is
  "no change / fix in-role / flag-only"). TD-001 is the standing example.

## P1 — Director consult (user)
- Present the plan, research findings, options, and recommendation; ask the
  Director's questions/opinions. Record the decision in the work order.
  (Director involvement is per-piece in build mode — this repo is establishing
  the organizational pattern, so default = consult, not auto-approve.)

## P2 — Adversarial review (Codex, pre-code)
- `codex exec` reviews the PLAN (not code): AGREE / REVISE / REFUSE with reasons.
- REVISE → fold in, re-run P2. REFUSE → back to P0 or Director.
- Record verdict + reasoning in the work order.

## P3 — Execution (Codex)
- On AGREE, Codex implements the piece in an isolated worktree
  (`git worktree add ../.worktrees/Cxx -b build/Cxx main`), within the
  scopeLock allowlist only.
- Gate to run green in the worktree: `yamllint`, `ansible-lint` (composed tree),
  `--syntax-check`, plus the piece's own proof (from proofOut).

## P4 — Validation (Claude)
- Claude reviews Codex's diff against the plan packet (plan adherence), the style
  guide (conformance), and re-runs the gate from the pinned SHA. Deviations →
  bounded Codex repair → re-validate.
- Full end-to-end runs against the lab VM happen ONLY from the clean snapshot:
  `scripts/revert-vm.sh` first, every time.

## P4.5 — Director file review (user)
- After P2 AGREE + Codex P3 + Claude P4 (all green), and BEFORE the P5 merge: Claude
  surfaces the final `present_windows.yml` (and any changed role file) into the
  Director's working view (main tree) and STOPS to ask "is this good?". Merge only on
  explicit Director approval; changes requested → bounded Codex repair in the worktree,
  re-surface, re-ask. (Director, 2026-07-15 — the Director reviews the actual role
  file, not just the plan packet.)

### P4.5 presentation format — LOCKED (Director, 2026-07-16: "mirror this EXACTLY")
The Director ratified the C02d P4.5 message as the canonical shape. Every P4.5 surface
mirrors it EXACTLY — same sections, same order, same voice:

1. **Intro line** — the preview is live/UNSTAGED in `<file>`, visible in VSCode Source
   Control under **Changes**; "Please review." Then a `---` rule.
2. **`## Cxx — <module> — ready for your review`** heading.
3. **`**The change**` (`<one-line what + where>`):** a fenced ```yaml block with the EXACT
   added/changed task(s), WHY comment included — nothing else.
4. **`**Cycle trace**`** — a markdown table, columns `Phase | Result`, one row each for
   `P2 (Codex)`, `P3 (Codex)`, `P4 (me)` (add a P4-repair row only if one happened). Each
   cell is a terse one-liner (verdict+reason / what was added / gate+convergence+
   idempotency+live-verification).
5. **`**Judgement calls**`** — a numbered list; every call either agent made, each with
   its justification. (If genuinely none: "None — <why>".)
6. **`**Files changed (role/playbook/style-guide):**`** — the scoped file list ONLY
   (role/playbook/style-guide, never `_handoff/` bookkeeping), each with a short what +
   a style-guide note or "No style-guide change".
7. **Closing question** — "Is this good to merge?"

Keep it tight: table + code excerpt + judgement calls are the load-bearing trio. No
preamble, no recap of the whole cycle, no options survey.

## P5 — Merge & codify
- Merge the validated SHA into `main` (--no-ff, `[audited <sha>]` annotation).
- Append the ledger row to `../REVIEW.md`; write/refresh `../steps/RTRACK-Cxx.md`.
- **Refresh `READMAP.md` (repo root) in the same codification commit** — hard rule
  (Director, 2026-07-15): forward roadmap statuses, locked decisions, the
  Director-decision queue, and the session handoff must reflect the just-merged state.
- Ratify/append any style-guide rules exercised by this piece (with the cycle ID),
  asking the Director where a rule is new or contested.
- Write a **judgement-decisions report** (in `RTRACK-Cxx.md`) of any call either agent
  made, with justification, **and a list of the Ansible role/playbook files + style
  guide updated** (Director 2026-07-15 — role/playbook/style-guide only, not the
  _handoff/ or process bookkeeping). The **P4.5 review IS the gate**; after merge + codify,
  proceed DIRECTLY to the next step's P0 — no separate post-merge stop (Director 2026-07-16).
