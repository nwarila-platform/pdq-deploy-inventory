# Tech debt register

## TD-001 — ansible-framework v3 loader is not Windows-aware

- **Recorded:** 2026-07-15 (Director decision: defer upstream fix, build role locally)
- **Where:** `applications/*/tasks/main.yml` (framework generic loader v3.0.0,
  byte-identical copy shipped in this repo's `wsus` role)
- **Gaps on a Windows target (SSH + PowerShell):**
  1. `INIT | Loading Installed Package Facts` runs `ansible.builtin.package_facts`
     (Python-only, no disable flag) → hard-fails on Windows.
  2. `INIT | Creating/Securing Temporary Directory` uses `ansible.builtin.tempfile` +
     POSIX/SELinux `file` attrs → Windows-incompatible (bypassable by design via
     `<role>.temp_dir: false`).
  3. Loader's explicit `ansible.builtin.setup` call: needs verification that it routes
     to `ansible.windows.setup` under `ansible_shell_type=powershell`; playbook-level
     `gather_facts: true` sidesteps it (loader skips when facts exist).
  4. Framework chassis `ansible.cfg` sets `become=True` with `sudo` → POSIX-only;
     Windows plays must set `become: false`.
- **Workarounds carried in `ansible/playbooks/wsus.yml`** (each marked `TD-001`):
  playbook-level fact gathering; `wsus.temp_dir: false` (role stages its own via
  `ansible.windows.win_tempfile`); pre-task seeding an empty `ansible_facts.packages`;
  play-level `become: false`.
- **Seed form (fixed C01/P4, commit 78cad4f):** the seed is
  `set_fact: packages: {} / cacheable: true`. It must NEVER set the name
  `ansible_facts` (the original `combine(...)` form did): a set_fact variable named
  `ansible_facts` shadows the live facts store and silently hides every later facts
  module's results (bit `win_disk_facts` in C01). The role must still not read
  `ansible_facts.packages` while the seed exists.
- **Override caveat (C01/P4):** an extra-vars `wsus:` dict REPLACES the playbook's
  `wsus:` dict; any `-e` override must re-state `temp_dir: false` or the loader's
  POSIX temp-dir path re-activates and fails the run.
- **Proper fix:** framework PR "loader v3.1 Windows support" — guard `package_facts`
  with `ansible_facts.os_family != 'Windows'`, add a `win_tempfile`-based temp-dir
  branch, document Windows become/transport expectations in the chassis. Any future
  Windows role needs this; the workarounds here are the evidence base for that PR.
  **Gate:** as a loader change, this proposal must pass
  `_handoff/loop/loader-change-protocol.md` (independent Fable + Sol validation,
  generic-preservation proof, Director acceptance) BEFORE the upstream PR is opened.
- **Exit criteria:** framework release containing v3.1 → bump `.framework-pin` →
  delete the playbook workarounds → close TD-001.

## TD-002 — chassis ansible-lint config conflicts with the ratified `#region` idiom

- **Recorded:** 2026-07-15 (C01/P4 discovery; pending Director disposition)
- **Where:** framework chassis `.ansible-lint` (`profile: safety`, `warn_list` lacks
  `yaml[comments]`)
- **Symptom:** the documented gate `(cd .compose/ansible-framework && ansible-lint
  applications/wsus)` exits 2 with every `#region`/`#endregion` banner counted as a
  fatal `yaml[comments]` violation (34 in the wsus role at C01). This is NOT a wsus
  problem: the framework's own `applications/python3_pip` fails its own gate
  identically (exit 2). The chassis `.yamllint.yml` already treats the same banners
  as warnings — the two chassis configs disagree about the established idiom.
- **Interim gate (used from C01 on, Codex-proposed / Claude-validated):**
  `ansible-lint --warn-list 'yaml[comments]' applications/wsus` — 0 failures /
  34 warnings, matching the yamllint stance. The verification snippet in `AGENTS.md`
  still shows the plain command; update it once the Director accepts this gate.
- **Proper fix:** upstream framework PR adding `yaml[comments]` to the chassis
  `.ansible-lint` `warn_list` (config-only; NOT a loader change, so the normal PR
  process applies — no loader-change-protocol gate needed). Evidence base: this
  entry + C01 lint logs.
- **Exit criteria:** framework release with the warn_list fix → bump
  `.framework-pin` → drop the `--warn-list` flag from the gate → close TD-002.

## TD-003 — local v3 loader carries a `validate.yml` hook not yet upstream

- **What:** `ansible/applications/wsus/tasks/main.yml` was bumped **v3.0.0 → v3.1.0** under a
  one-time Director-approved exception (dual-panel Fable + Sol: unanimous APPROVE, per
  `_handoff/loop/loader-change-protocol.md`) to add a GENERIC `INIT | Validating Merged
  Configuration` hook: after merging the running config, the loader includes the role's optional
  `tasks/validate.yml` (`first_found`, skipped if absent), passing the merged `config`. This gives
  every role a place to assert its MERGED-config contract, which `meta/argument_specs.yml` cannot see.
- **Debt:** the loader is no longer **byte-identical / hash-matched** to the framework's v3.0.0
  (the ratified invariant, style §3). Until the framework adopts v3.1.0, the local loader diverges.
- **Rollout (panel conditions):** upstream v3.1.0 to `ansible-framework` **atomically** — every v3
  loader copy (applications/wsus, applications/python3_pip, all v3 consumers) to identical v3.1.0
  bytes in one commit; grep every consumer repo (incl. the 4 wazuh roles) for a pre-existing
  `tasks/validate.yml` before release; then bump `.framework-pin`, re-copy, and re-verify sha256
  equality → close TD-003 (restores the byte-identical invariant).
- **Evidence:** RTRACK-V + the Fable/Sol verdicts (loader-change gate).

## TD-004 — WsusPool tuning uses the deprecated `community.windows.win_iis_webapppool`

- **What:** C08 tunes the WsusPool IIS app pool with `community.windows.win_iis_webapppool`. That
  module is **deprecated for removal in `community.windows` 4.0.0**, superseded by
  `microsoft.iis.web_app_pool`.
- **Why not switched now (C08 P2 r1 decision):** `microsoft.iis` is **NOT installed** in this
  controller's collection set (only `community.windows 3.3.0` + `ansible.windows`). Switching would
  add a new collection dependency (a framework/galaxy change) for a module that works today; the
  removal is a future 4.0.0 event, not present in 3.3.0.
- **Debt:** the role depends on a module slated for removal; a future `community.windows` 4.x bump
  would break C08.
- **Rollout:** when the collection set is next bumped (or `microsoft.iis` is added as a dependency),
  migrate the `MAIN | Tune WsusPool Application Pool` task from `community.windows.win_iis_webapppool`
  to `microsoft.iis.web_app_pool` (verify the `attributes` mapping / parameter shape), add
  `microsoft.iis` to the composition's collection requirements, and re-run the C08 proofs → close TD-004.

## TD-005 — v3 loader echoes the merged `<role>_running` config (incl. secrets) at `-v`

- **What:** the framework v3 loader's `INIT | Loading Overrides` task `set_fact`s the merged
  `<role>_running` dict (the style-guide-SANCTIONED persistent config — R3's named exception). When a
  secret lives in the override dict (P05: `pdq.service_account.password`), that secret becomes a
  persistent HOST FACT and is printed in full on any `-v`+ run (Ansible prints `set_fact` results at
  verbosity ≥ 1). Proven with a sentinel password 2026-07-28 (P05 P4).
- **Scope:** the **v3 loader — GOVERNANCE SURFACE** (byte-identical, untouchable per-role); affects
  EVERY secret-bearing role composed on it, not just pdq. P05 is merely the first pdq piece to route a
  secret through the loader.
- **Not a leak at default verbosity:** normal runs (no `-v`) do NOT print it — proven, 0 sentinel
  occurrences. The consuming task's own `no_log` (P05's `win_user`) also works. The residual exposure is
  `-v`+ runs (e.g. a verbose CI log) plus the play-duration host-fact persistence of the secret.
- **Mitigations already in place:** secrets supplied via `-e @<non-committed protected file>` or vault
  (never a literal `-e`), so command-line / shell-history / process-listing exposure is already avoided.
- **Fix / rollout:** add `no_log: true` to the loader's override-merge `set_fact` (suppresses the `-v`
  print of the merged config). This is a loader change → `_handoff/loop/loader-change-protocol.md` (one
  independent Claude/Fable + one Codex 5.6/Sol validator both confirm it is a generic improvement fitting
  EVERY role, then the Director accepts). Recommended; does NOT block role pieces. Raised 2026-07-28 (P05).
- **Evidence:** RTRACK-P05 "Finding → TD-005"; the P05 P4 sentinel-hygiene proof.
- **Evidence:** C08 packet `moduleChoice.moduleDeprecationNote` + RTRACK-C08.
