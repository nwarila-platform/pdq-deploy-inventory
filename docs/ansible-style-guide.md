# nwarila-platform — Ansible style & design guide

> **STATUS: DRAFT — rules are ratified one at a time during build cycles.**
> Each rule carries a status: `RATIFIED` (Director-approved, enforceable),
> `SEEDED` (decided at kickoff, pending in-cycle validation), or `TBD`.
> Golden references: `wazuh_agent` (task-file authoring idiom, newest wazuh-repo role)
> and `ansible-framework/applications/python3_pip` (framework fit, loader v3 contract).

## 1. Repo & composition model — SEEDED (kickoff 2026-07-15)

- One single-purpose role per application repo; the repo composes into a
  version-pinned `ansible-framework` checkout at execution time (`.framework-pin`,
  `scripts/compose-and-run.sh`). Roles must be drop-in compatible with the framework's
  `applications/` namespace (`roles_path` resolution by bare name).
- The framework is the chassis: `ansible.cfg`, lint configs, loader contract, CI
  conventions all originate upstream. Application repos copy `.yamllint.yml` /
  `.editorconfig` for local dev parity.

## 2. Naming — SEEDED

- Repo: `windows-wsus` (OS-prefixed product). Role: `wsus` (bare product name,
  resolves via framework `roles_path`). Playbook: `wsus.yml`. Inventory group:
  `wsus_servers` (pluralized component, mirrors `wazuh_indexers`).
- Role defaults live under `<role>_defaults` in `defaults/main.yml`; the merged
  running config materializes as `<role>_running`; playbook overrides use the bare
  `<role>:` dict. (Loader v3 contract.)

## 3. Loader contract — SEEDED (framework v3.0.0)

- Every role ships the framework's generic loader as `tasks/main.yml`,
  **byte-identical, never edited per-role**. Loader changes are governance-surface →
  upstream framework PR only.
- **RATIFIED (Director, 2026-07-15):** `tasks/main.yml` is intentionally a generic,
  hash-matched global loader. Any recommended change and/or optimization
  recommendation targeting it MUST be validated by **two independent agents from
  different model families — one Claude (Fable) and one Codex 5.6 (Sol)** — each
  independently confirming (i) the change is warranted at all (default NO) and
  (ii) it is a generic improvement that fits EVERY consuming role comfortably,
  preserving the hash-match invariant. Full gate:
  `_handoff/loop/loader-change-protocol.md`. Unanimous agreement + Director
  acceptance required; otherwise the loader does not change.
- OS task files: `<state>_<family>[_<dist>[_<ver>]].yml`, resolved most-specific-first
  via `first_found`. This role ships `present_windows.yml` + `clean_windows.yml`
  (family-level; `os_family=Windows`).
- Vars overlays: `vars/<family>[_...][_<env>].yml`, recursive combine,
  `list_merge='replace'`. `ENV` is mandatory and regex-validated by the loader.

## 4. Task authoring idioms — SEEDED (from wazuh_agent + python3_pip; ratify per cycle)

- Task names: `'STAGE | Imperative description'` — stages observed: `INIT`, `MAIN`,
  `BEGIN` (input guards), `END` (verification), `Cleanup`, `INFO` (block wrappers).
- `#region` / `#endregion` banner comments delimit logical sections; files open with
  the boxed header comment (`File:`, description, version where applicable).
- Fully-qualified collection names always (`ansible.builtin.*`, `ansible.windows.*`).
- Asserts use `quiet: true` with actionable, templated `fail_msg`.
- Comments explain WHY (contract, failure modes), not what.
- Service/state verification: retry loops with explicit `retries`/`delay`/`until`
  rather than fixed sleeps (wazuh_agent END-stage pattern).
- **Avoid `set_fact` for role-internal derived/intermediate data — RATIFIED (R3, 2026-07-15).**
  `set_fact` registers HOST FACTS that persist for the rest of the play and BLEED into later
  roles (variable pollution + surprising precedence). Use scoped alternatives: block `vars:`
  (lazily evaluated, block-scoped), task `vars:`, or `register`. Reserve `set_fact` for values
  that persist BY CONTRACT (e.g. the loader's `<role>_running` merged config) and namespace them
  (`<role>_*` / `__dunder__`).

## 4a. Role scope — the "handed machine" contract — RATIFIED (Director, 2026-07-15)

- The application role configures the target **end-to-end**. Its input contract is a
  machine handed to it as **OS + reachable SSH + attached-but-blank data disks** —
  exactly what a fresh Terraform-provisioned (today: snapshot) VM provides. From that
  point the role owns **all guest OS state**: storage init (Initialize/format/label/
  assign), features, app install, configuration, and verification.
- **Boundary:** *hardware provisioning* (disk count/size/attachment, vCPU/RAM, NIC)
  belongs to the deploy layer (baseline snapshot now, proxmox-terraform-framework
  later). *Guest OS state* belongs to the role. Formatting a disk into the baseline
  image is FORBIDDEN — it must be role-declared code, proven on every clean revert.
- This intentionally **diverges from wazuh**, where storage prep is an operator/packer
  prerequisite outside the app role. For nwarila-platform Windows app repos the app
  role is the single E2E configurator of the machine it is handed.
- Disk identification is **declarative by a stable per-disk identifier — never
  disk-number- nor size-coupled** (amended C01r, 2026-07-15): select the target disk
  by its declared `unique_id` (Windows Get-Disk `UniqueId` / `win_disk_facts.unique_id`,
  e.g. `eui.<hex>`), supplied as a REQUIRED input — never by size and never by
  enumeration number, so the role is robust to enumeration order AND size changes.
  (`unique_id` is populated on RAW/blank disks and stable through GPT initialization.)

## 4b. Guards earn their keep — RATIFIED (C01/C01r seeded; policy ratified V, 2026-07-15)

**Prefer the Ansible action; assert only when load-bearing.** An assert is admitted only if
BOTH prongs clear:
- **(a) Don't assert what fails anyway.** Never pre-assert a precondition an Ansible action
  already fails loudly on — lean on that failure (the loader's `first_found` + "OS task file not
  found" enforces os_family; `win_initialize_disk` fails on an absent/bad `uniqueid`; the
  exactly-one resolution rejects a missing/empty id as "found 0"). A friendlier or earlier message
  for a state a module would reject anyway is NOT sufficient justification.
- **(b) Configure, don't assert.** Never assert a state you can idempotently CONFIGURE — configure
  it (`win_initialize_disk online:true` MAKES the disk online/writable; do not assert it is).
An assert is **RETAINED only** when a wrong state is **SILENT-WRONG or DESTRUCTIVE and no Ansible
action catches it before the damage** — e.g. two logical volumes declared onto one physical disk
(equal ids → both resolve to one disk → half-provisioned), or a foreign/occupied initialized disk
(`win_initialize_disk force:false` no-ops, then `win_partition -1` carves its free extent → silent
clobber, verified at the module source). These stay `quiet: true` with an actionable fail_msg.
(§4c is the destructive analog; §4a the identifier rule.)

**Guard / validate-stage shape:**
- The guard stage is **read-only on the target**: facts gathering, asserts, and **scoped
  resolution vars** — a block `vars:` attribute deriving a declared-spec → resolved-object from
  gathered facts (no mutation, and NEVER `set_fact`, which bleeds across roles — see §4). The
  first *mutating* task belongs to the piece that owns it, never a guard. (Exercised: R3 —
  `__data_disks__[].matches` resolves each disk once, reused by the Attached assert + safety guard.)
- Facts are gathered **once**, at the superset the load-bearing path needs; a mutating piece owns
  its own post-mutation refresh.
- Declarative resource selection resolves to **exactly one** match per declared spec (assert
  `length == 1`, enumerating fail_msg; then reuse the resolved object — never re-select with a bare
  `| first`). Zero and multiple are both hand-off failures. Declared specs must be mutually
  distinguishable (e.g. distinct identifiers).
- The declared CONFIG contract (post-merge `config.*`) is validated in ONE place where `config` is
  in scope — the role's `tasks/validate.yml`, run by the v3.1.0 loader's
  `INIT | Validating Merged Configuration` hook — **never** `meta/argument_specs.yml` (structurally
  blind to the merged `config`; see §8).
- Guard pieces carry a negative proof (deliberately-wrong input fails on the intended assert;
  sibling specs still pass). (Exercised: C01 / C01r / C02a / C02b / V.)

## 4c. Mutation safety — SEEDED (C02b, 2026-07-15)

- A piece that MUTATES a declared resource carries a **state-aware safety assert BEFORE
  the first mutation** — the destructive analog of the §4b read-only guard. It refuses
  to clobber a resource that does not match the managed layout, recognizing an
  already-managed target by a **declared convention** (e.g. the disk's target drive
  letter), NEVER by size or enumeration number. Blank/RAW, already-ours, and neutral
  (unlettered) states proceed; a foreign/occupied state refuses loudly with an
  actionable `fail_msg`. (Exercised: C02b — RAW or our-drive-letter → provision; a
  foreign drive letter → refuse. Idempotency: recognizing 'ours' lets a converged
  resource pass, which a blank-only guard would wrongly reject.)

## 5. Windows conventions — SEEDED (first Windows role; ratify via research per cycle)

- Transport: **SSH** (org standard; key auth, one transport story across the fleet).
  `ansible_shell_type: powershell`; target's OpenSSH `DefaultShell` = PowerShell.
- `become: false` at play level (framework chassis `become=sudo` is POSIX-only;
  built-in administrator over SSH is already elevated). Revisit for least-privilege
  runs (runas) when a non-admin service account is introduced — TBD.
- Windows modules from `ansible.windows` (fallback `community.windows`); never invoke
  raw PowerShell where a module exists — escape-hatch threshold decided at C05, see the
  PROPOSED (C05) rule below.
- Loader Windows gaps are TD-001 workarounds in the playbook, not role hacks — see
  `docs/TECH-DEBT.md`.
- **RATIFIED (C02a, 2026-07-15 — supersedes the C01r §5-ext) — required per-target
  inputs live in the `<role>:` override dict, consumed via `config`.** Environment-
  specific inputs the role cannot default (e.g. disk identifiers `wid_disk_id` /
  `wsus_disk_id`) are declared inside the `<role>:` override dict (playbook /
  group_vars / host_vars) and read as `config.<key>`, matching the framework/wazuh
  idiom and the loader's `defaults -> overlays -> <role> override -> config` merge.
  Only `ENV`/`state` stay top-level (loader-level). NOTE: a `-e '{"<role>":{...}}'`
  override REPLACES the whole dict, so co-locate loader-read keys (`temp_dir`) with any
  `-e`/override-provided keys, and any override must re-state them. The README documents
  these as merged config, not top-level vars.
- **PROPOSED (C01):** never `set_fact` the name `ansible_facts` — the resulting
  set_fact variable shadows the live facts store and silently hides every later
  facts module's results (proven C01/P4: `win_disk_facts` results invisible until
  the TD-001 seed was rewritten to `packages: {} / cacheable: true`).
- **PROPOSED (C05, P2-refined) — the escape-hatch policy.** Native module FIRST, always
  (C05 verified the gap empirically: 0 of 118 modules across `ansible.windows` +
  `community.windows` cover WSUS server ops). Where no module exists:
  1. `ansible.windows.win_command` in **`argv` form** is the sanctioned escape hatch
     (each element auto-quoted per Win32 rules — spaced paths are a non-issue; no shell
     parsing surface).
  2. `win_shell` ONLY for genuine shell semantics — e.g. a PowerShell **cmdlet**
     (`Get-WsusServer`), pipes, redirects. Never for plain .exe invocation.
  3. Idempotency: `creates:`/`removes:` ONLY when the marker reliably represents
     **completed** desired state. An artifact the command creates EARLY in its run does
     NOT qualify — a midway failure leaves it behind and every later run silently
     false-converges (C05/P2 rejected the community-standard `creates: ...\WSUSContent`
     for exactly this). Where no reliable completion file exists, use the
     **probe-gates-actor idiom**: a read-only registered probe
     (`changed_when: false`, `failed_when: false` — nonzero rc IS the signal, not an
     error) gating the mutating command via `when:` (C05: `Get-WsusServer` gating
     `wsusutil postinstall`; the UpdateServicesDsc model, implemented natively).
  4. No `chdir` when the tool has no working-directory requirement; invoke by absolute
     path. No asserts on undocumented/localizable stdout — rc + a functional probe are
     the contract.
- **RATIFIED (C06c P4.5, Director 2026-07-16) — embedded PowerShell follows OTBS.** Any
  multi-statement PowerShell inside a `win_shell` block scalar uses One True Brace Style:
  opening brace on the statement line; cuddled `} elseif (...) {` / `} else {`; multi-statement
  bodies on their own indented lines (4-space); NO semicolon statement-chaining; blank lines
  between logical sections. Idiomatic one-line pipeline filter blocks
  (`Where-Object { ... }`) stay inline — OTBS governs control statements. First applied:
  the C06c relocation probe; binding on all later embedded scripts (C06e/C06g+).
- **RATIFIED (M, 2026-07-17) — the native-module template for `win_shell` §8 escape hatches.**
  Every mutating `win_shell` block that stands in for a missing native module MUST act like one:
  1. `$ErrorActionPreference = 'Stop'` is the FIRST statement (a mid-script non-terminating error
     must not pass silently).
  2. Inputs arrive via `environment:` (env-passing), NEVER Jinja-interpolated into the PowerShell
     source (`'{{ x }}'`) — env-passing removes an injection + `split_args` surface. Architectural
     constants (e.g. the WID pipe connection string `__wid_conn_master__`) are defined ONCE in the
     task file's `vars:` block and env-passed, not duplicated per block.
  3. Any external resource (a `SqlConnection`) is opened inside `try { } finally { <close-only> }`
     — the `finally` closes and does nothing else (no `catch`, no swallow); intentional
     fail-closed `throw`s (e.g. Attach's DROP-on-unhealthy) stay inside `try` before the finally.
  4. Idempotency by a normalized compare → mutate-on-diff → **re-acquire-and-verify** → deterministic
     `changed`/`nochange` (or a read-only probe with `changed_when: false`), never blind mutation.
  5. Embedded PowerShell follows OTBS (above). First applied wholesale across the C06 SqlClient
     blocks; the C09b Grant-SYSTEM block is the reference implementation.
- **RATIFIED (C12c seed → M, 2026-07-17) — never put a backslash immediately before a closing quote
  (`\'` / `\"`) in `win_shell`/`win_command` free-form; enforced by an automated gate.** Ansible parses
  the free-form module arg with `split_args`, which honors `\` as an escape **even inside single quotes**.
  A literal backslash right before a closing quote — `Replace('/','\')`, `'IIS:\Sites\'`, `'C:\'` —
  escapes the quote, unbalances the parser, and fails the task at **LOAD time**
  (`failed at splitting arguments…`). Interior backslashes are fine (`'IIS:\Sites\Default Web Site'`);
  only backslash-adjacent-to-a-closing-quote breaks. **RULE:** build such strings with `[char]92`
  (`$dir.TrimEnd([char]92) + [char]92`) and never end a quoted literal with `\`. **GATE:**
  `scripts/check-winshell-splitargs.py` (run with the ansible-core venv python) fails on any
  `split_args` error OR any backslash-before-quote across every `win_shell`/`win_command` block — this
  is the ONLY static check that catches the class: yamllint, ansible-lint, AND
  `ansible-playbook --syntax-check` all pass an unbalanced-`\'` regression (proven M, 2026-07-17; it is
  exactly how the C12c bug shipped). Part of the standard gate now.
- **SEEDED (U1, 2026-07-16 — Director directive, P2-narrowed) — Users browse-access ACL
  hygiene.** Role-created directories INTENDED FOR INTERACTIVE ADMINISTRATION/BROWSING,
  under an explicitly documented trust model ("all interactive users are admins"), get an
  explicit `BUILTIN\Users` ReadAndExecute grant (`win_acl`, allow,
  `ContainerInherit, ObjectInherit`) co-located with their creation. WHY: an unreadable
  folder makes Explorer offer "Continue", which stamps the browsing admin's PERSONAL ACE
  onto the ACL — stale/orphaned SIDs after they depart. Explicit, never inherited-by-luck
  (format-default root ACLs evaporate under hardening). EXCLUDED BY DEFAULT: secrets,
  private service data, product-managed ACL boundaries (e.g. WSUSContent — postinstall
  owns it). `E:\WID\Data` is an explicit Director-approved exception in this role.

## 6. Controller & toolchain — SEEDED

- pipx-installed `ansible-core` pinned to the framework's supported range
  (currently 2.21.x), plus `ansible-lint`, `yamllint`. Collections pinned:
  `ansible.windows`, `community.windows`.
- Windows targets are never long-lived dev state: revert the lab VM to the clean
  baseline snapshot before every playbook execution (`scripts/revert-vm.sh`).
- **Lint from the composed tree** (proof S4b, 2026-07-15): the playbook's role
  resolves only inside the composed framework checkout, so `ansible-lint` runs from
  `.compose/ansible-framework/` (which also supplies the chassis `.ansible-lint`
  profile). Repo-side `ansible-lint <playbook>` fails `syntax-check` by design — do
  not "fix" that by vendoring a roles_path shim without a ratified rule.
- SSH multiplexing is isolated per-repo (`.compose/.cp`, pre-cleaned every run) —
  stale ControlMaster sockets from killed runs or VM reverts hang plays silently
  (proof S3, 2026-07-15).

## 7. Commits & process — SEEDED

- Conventional Commits, scope = role name or `framework` (framework CI enforces
  upstream; this repo follows the same format).
- Build process: one command per cycle via `_handoff/loop/STRICT-CYCLE-adapted.md`;
  every cycle ends with a ledger row and any style-rule ratifications recorded here
  with the cycle ID.

## 8. Open questions (moved to RATIFIED/rule sections as cycles decide them)

- ~~`win_shell`/`win_command` escape-hatch policy and idempotency guards~~ — **DECIDED
  (C05, 2026-07-16):** moved to the PROPOSED (C05) rule in §5; pending Director
  ratification.
- Handler usage & service-restart conventions on Windows.
- Molecule (or equivalent) test story for Windows roles — framework roles ship
  `molecule/`; no Windows driver decision yet.
- Argument specs (`meta/argument_specs.yml`) — **DECIDED (V, 2026-07-15): NOT adopted for
  enforcement.** The auto-inserted arg-spec validator runs BEFORE the v3 loader builds the merged
  `config` (verified empirically), so it is structurally blind to `config.*` and only duplicates the
  loader's ENV/state assert. Merged-config validation lives in the role's `tasks/validate.yml` (run
  by the loader's v3.1.0 `INIT | Validating Merged Configuration` hook, §4b). argument_specs is
  permissible only as description-only documentation of the `<role>:` dict shape. _(superseded note)_ wazuh roles use them; python3_pip's
  meta shape TBD against it.
- Secrets handling for Windows (no vault usage yet in this repo).
