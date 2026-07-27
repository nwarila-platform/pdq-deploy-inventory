# Loader-change protocol — tasks/main.yml multi-LLM generic-preservation gate

`ansible/applications/wsus/tasks/main.yml` is the **generic role loader** (framework
v3.0.0): a byte-identical, hash-matched copy of the canonical loader in
`nwarila-platform/ansible-framework` (`applications/*/tasks/main.yml`), shared by EVERY
role in the organization. It is a deliberately-built **generic executor** and a
**governance surface**. No change to it goes through the normal cycle, and it is NEVER
edited locally in this repo — the canonical source is upstream.

Directive (Director, 2026-07-15, extending the 2026-07-14 wazuh directive): *"tasks/main.yml
is intentionally a generic loader. Any recommended change and/or optimization
recommendation there MUST require 1 independent agent from both Claude (Fable) and
Codex 5.6 (Sol) to validate the recommendation and ensure it is a generic improvement
that will fit into EVERY role comfortably, as it is the hash-matched global loader."*

## Trigger

- Any P0 whose `scopeLock.fileAllowlist` would include a `tasks/main.yml`, or any
  change that would alter loader behavior; **and equally**
- any *recommendation or optimization proposal* targeting the loader, even before a
  diff exists. Recommendations do not become accepted recommendations until they pass
  this gate. (Standing example routed here: TD-001 — loader v3.1 Windows support.)

## Gate (replaces P2/P3 for loader changes; P4/P5 still follow)

1. **HALT for the Director.** Governance surface → Director must accept before and
   after. Plan packet carries `haltDecision.halt = true,
   reasons: ["governance-surface: tasks/main.yml"]`.

2. **Two INDEPENDENT validators, different model families** — one from each, both
   read-only, both given the proposal, the loader source at the framework pin, and the
   full consumer inventory (every role that ships the loader: this repo's `wsus`,
   framework `applications/*` + `operating_systems/*`, wazuh's four roles, and any
   sibling repo roles). Current designations (Director-updatable as models evolve):
   - **Validator A = Codex 5.6 "Sol"** — `codex exec -c sandbox_mode="read-only"`.
   - **Validator B = Claude "Fable"** — Agent tool, `model: fable`, read-only
     (Explore-class) from the pinned checkout.

   Each independently returns a written report with BOTH halves:
   - **WHY (recommendation):** should the loader change at all? **Default is NO** —
     prefer fixing in the role's task files / defaults, a documented playbook
     workaround (TD pattern), or flag-only. A loader change must be justified as the
     *only correct* fix: the defect/improvement genuinely belongs to the generic
     executor, not to any role's use of it.
   - **GENERIC-PRESERVATION VERIFICATION:** concrete proof the change keeps the loader
     a pure generic executor —
     a. No per-role, role-name-coupled, product-specific, or OS-assumption logic that
        narrows the loader (Windows support must be additive, not RedHat-regressive).
     b. **v3 contract preserved:** ENV + state assert (regex, allowed set); fact
        gather skip-if-cached; package-facts guard semantics; overlay cascade
        (interleaved OS×ENV, recursive combine, `list_merge='replace'`);
        `<role_name>_running` merge chain incl. bare `<role>` override dict;
        `<state>_<family>[_<dist>[_<ver>]].yml` `first_found` dispatch + loud failure;
        `config` var scoping into the included file; temp-dir create/secure/disable
        flag; `always:` cleanup.
     c. **Hash-match invariant:** the change lands in the UPSTREAM framework and rolls
        out identically to every consumer (this repo consumes via `.framework-pin`
        bump + re-copy; verify `sha256sum` of the role copy == framework copy at the
        pin). Any transitional divergence is called out explicitly with its rollout
        plan.
     d. Fits EVERY consumer comfortably: no regression reasoning per consumer class
        (RedHat roles, Windows roles, framework OS-bootstrap roles).

3. **Decision:** proceed ONLY if BOTH validators independently (i) recommend the
   change AND (ii) confirm generic preservation. Any REFUSE / "fix in-role" /
   "flag-only" from either → the loader does NOT change; record the outcome (that is
   a valid, expected result) and route the need to a role-local fix or TD entry.

4. **If both agree →** the change is proposed UPSTREAM (ansible-framework PR,
   conventional commits, framework CI). After upstream merge/release:
   `.framework-pin` bump → re-copy loader into the role → hash-verify → normal P4
   validation (re-verify hash-match) → **Director acceptance** at P5 before merge.

## Output

Both validator reports (verbatim verdicts) + the synthesized decision go in the
piece's `RTRACK-Cxx.md` and a `REVIEW.md` ledger row. "No change" closes the piece as
flag-only with the recommendation recorded.
