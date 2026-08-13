# nwarila-platform — Ansible style & design guide

> **STATUS: DRAFT — rules are ratified as the implementation evolves.**
> Each rule carries a status: `RATIFIED` (Director-approved, enforceable),
> `SEEDED` (decided at kickoff, pending in-cycle validation), or `TBD`.
> Golden references: `wazuh_agent` (task-file authoring idiom, newest wazuh-repo role)
> and `ansible-framework/applications/python3_pip` (framework fit, loader v3 contract).

## 1. Repo & composition model — SEEDED (kickoff 2026-07-15)

- One coherent capability per role; this repository carries the separate
  `pdq_inventory` and `pdq_deploy` application roles and composes them into a
  version-pinned `ansible-framework` checkout at execution time (`.framework-pin`,
  `scripts/compose-and-run.sh`). Roles must be drop-in compatible with the framework's
  `applications/` namespace (`roles_path` resolution by bare name).
- The framework is the chassis: `ansible.cfg`, lint configs, loader contract, CI
  conventions all originate upstream. Application repos copy `.yamllint.yml` /
  `.editorconfig` for local dev parity.

## 2. Naming — SEEDED

- Repo: `pdq-deploy-inventory`. Roles: `pdq_inventory` and `pdq_deploy` (bare
  capability names resolved via framework `roles_path`). Playbook: `pdq-aws.yml`.
  Inventory group: `pdq_servers`.
- Role defaults live under `<role>_defaults` in `defaults/main.yml`; the merged
  running config materializes as `<role>_running`; playbook overrides use the bare
  `<role>:` dict. (Loader v3 contract.)
- **RATIFIED (Director, 2026-07-31):** When copying, splitting, or renaming a role,
  rename its `defaults/main.yml` top-level key to `<new_role_name>_defaults`; the
  loader resolves it from `role_name`, so a stale key silently yields empty config.
- **RATIFIED (Director, 2026-07-31):** Reconcile the composed execution tree when a
  role is renamed or removed. Before lint or live validation, fail unless every new
  role directory is present and every retired role directory is absent; overlay
  composition does not remove sources that no longer exist.

## 3. Loader contract — SEEDED

The two local loaders are currently v3.1.0 and diverge from the pinned framework
loader v3.3.0 (verified 2026-08-10); the difference is tracked in
`docs/TECH-DEBT.md`.

- Every role must ship the framework's generic loader as `tasks/main.yml`,
  **byte-identical, never edited per-role**. Loader changes are governance-surface →
  upstream framework PR only.
- **RATIFIED (Director, 2026-07-15):** `tasks/main.yml` is intentionally a generic,
  hash-matched global loader. Any recommended change and/or optimization
  recommendation targeting it MUST be validated by **two independent reviewers** — each
  independently confirming (i) the change is warranted at all (default NO) and
  (ii) it is a generic improvement that fits EVERY consuming role comfortably,
  preserving the hash-match invariant. Unanimous agreement + Director
  acceptance required; otherwise the loader does not change.
- OS task files: `<state>_<family>[_<dist>[_<ver>]].yml`, resolved most-specific-first
  via `first_found`. This role ships `present_windows.yml` + `clean_windows.yml`
  (family-level; `os_family=Windows`).
- **RATIFIED (Director, 2026-07-31):** A role's `tasks/` directory contains only the
  generic `main.yml` loader, loader-resolved OS entrypoints, and `validate.yml`; this
  list is exhaustive. Do not add other task files or split an entrypoint with a sibling
  `include_tasks`; an entrypoint that needs splitting signals an over-broad role (§4d).
- **RATIFIED (Director, 2026-07-31):** Keep `tasks/` flat:
  `scripts/check-winshell-splitargs.py` scans `applications/*/tasks/*.yml`
  non-recursively, so a nested task file silently escapes the inline-PowerShell gate.
- Vars overlays: `vars/<family>[_...][_<env>].yml`, recursive combine,
  `list_merge='replace'`. `ENV` is mandatory and regex-validated by the loader.

## 4. Task authoring idioms — SEEDED (from wazuh_agent + python3_pip; ratify per cycle)

- Task names: `'STAGE | Imperative description'` — stages observed: `INIT`, `MAIN`,
  `BEGIN` (input guards), `END` (verification), `Cleanup`, `INFO` (block wrappers).
- `#region` / `#endregion` banner comments delimit logical sections; files open with
  the boxed header comment (`File:`, description, version where applicable).
- Fully-qualified collection names always (`ansible.builtin.*`, `ansible.windows.*`).
- Asserts use `quiet: true` with actionable, templated `fail_msg`.
- **RATIFIED (Director, 2026-08-05):** A `when:` expression referencing an
  operator-supplied variable uses the default-and-normalize form
  `(state | default('present') | string | lower | trim) == 'present'`, never the bare variable;
  omission otherwise hard-fails the play.
- Comments explain WHY (contract, failure modes), not what.
- Service/state verification: retry loops with explicit `retries`/`delay`/`until`
  rather than fixed sleeps (wazuh_agent END-stage pattern).
- **RATIFIED (Director, 2026-08-05):** A delivery chain that downloads and stages
  an installer hash-verifies the pinned checksum at the execution site — the staged
  guest copy, immediately before execution — not only at the download site.
- **Avoid `set_fact` for role-internal derived/intermediate data — RATIFIED (R3, 2026-07-15).**
  `set_fact` registers HOST FACTS that persist for the rest of the play and BLEED into later
  roles (variable pollution + surprising precedence). Use scoped alternatives: block `vars:`
  (lazily evaluated, block-scoped), task `vars:`, or `register`. Reserve `set_fact` for values
  that persist BY CONTRACT (e.g. the loader's `<role>_running` merged config) and namespace them
  (`<role>_*` / `__dunder__`).
- **RATIFIED (Director, 2026-08-06) — never rebind a gated-block predicate variable.**
  A task inside a `when:`-gated block must not rebind through task `vars:` any name
  referenced by the inherited condition. Use a distinct data name and restate the
  predicate over later data; keep both expressions synchronized. Static lint does not
  detect this skipped-task failure.
- **RATIFIED (Director, 2026-07-31):** A task whose registered result is consumed to
  report success or failure uses `ignore_errors: true`, not `failed_when: false`;
  `failed_when: false` rewrites `.failed` and makes a real module error report success.
- **RATIFIED (Director, 2026-08-05):** An `always:` cleanup removes a fixed staging
  path only when gated on the register of the task that staged it; a run that never
  reached staging never deletes the path.
- **RATIFIED (Director, 2026-07-31):** Place a conditionally included unit's
  postconditions after and outside its `include_tasks`, so verification also runs on
  the converged path where the include is skipped.
- **RATIFIED (Director, 2026-07-31):** A `rescue` preserving a failure projects only a
  guarded field, never the whole `ansible_failed_result`:
  `{{ ansible_failed_result.msg | default('<role> operation failed', true) }}`. Whole
  results can expose invocation data, and an unguarded missing field can mask the
  original failure during argument finalization.
- **RATIFIED (Director, 2026-07-31):** Apply `no_log: true` where a secret is a task
  argument or arbitrary result data is captured; remove it where neither holds, because
  decorative `no_log` destroys diagnostics. Secret audits cover every accepted parameter
  name and alias, registered variables, and whole-result persistence; claims describe
  only those verified surfaces.
- **RATIFIED (Director, 2026-07-31):** An include for a unit that cannot support check
  mode carries `not ansible_check_mode` explicitly, so `--check` skips it honestly
  instead of beginning work and failing.

## 4a. Role scope — the "handed machine" contract — RATIFIED (Director, 2026-07-15)

- **RATIFIED (Director, 2026-07-31) — composed-play ownership amendment.** The
  composed play and its ordered roles configure the target end-to-end. Their input is a
  machine handed to it as **OS + reachable SSH + attached-but-blank data disks** —
  the contract for a freshly provisioned machine. From that point the shared
  `windows_disk_manager` role owns disk initialization through drive assignment; each
  application role owns its application installation, configuration, and verification.
- **Boundary:** *hardware provisioning* (disk count/size/attachment, vCPU/RAM, NIC)
  belongs to the deploy layer. *Guest OS state* belongs to the composed play. Formatting
  a disk into the source machine image is FORBIDDEN — it must be role-declared code,
  proven on every fresh provision.
- This intentionally **diverges from wazuh**, where storage prep is an operator/packer
  prerequisite outside the composed play. Here the composed play is the end-to-end
  configurator of the machine it is handed.
- Disk identification is **declarative by a stable per-disk identifier — never
  disk-number- nor size-coupled** (amended 2026-07-15): select the target disk
  by its declared `unique_id` (Windows Get-Disk `UniqueId` / `win_disk_facts.unique_id`,
  e.g. `eui.<hex>`), supplied as a REQUIRED input — never by size and never by
  enumeration number, so the role is robust to enumeration order AND size changes.
  (`unique_id` is populated on RAW/blank disks and stable through partition-table initialization.)

## 4b. Guards earn their keep — RATIFIED (2026-07-15)

**Prefer the Ansible action; assert only when load-bearing.** An assert is admitted only if
BOTH prongs clear:
- **(a) Don't assert what fails anyway.** Never pre-assert a precondition an Ansible action
  already fails loudly on — lean on that failure (the loader's `first_found` + "OS task file not
  found" enforces os_family; `win_initialize_disk` fails on an absent/bad `uniqueid`; the
  exactly-one resolution rejects a missing/empty id as "found 0"). A friendlier or earlier message
  for a state a module would reject anyway is NOT sufficient justification.
- **(b) Configure, don't assert.** Never assert a state you can idempotently CONFIGURE — configure
  it (`win_initialize_disk online:true` MAKES the disk online/writable; do not assert it is).
**Required-input exception.** An assert in `tasks/validate.yml` may enforce a documented
"REQUIRED in the override dict, no safe default" input contract when its `fail_msg` names the
missing input and the override that must declare it. This is a distinct admission class; ordinary
friendlier or earlier-failure asserts remain forbidden by (a).
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
  first *mutating* task belongs to the component that owns it, never a guard.
- Facts are gathered **once**, at the superset the load-bearing path needs; a mutating component owns
  its own post-mutation refresh.
- Declarative resource selection resolves to **exactly one** match per declared spec (assert
  `length == 1`, enumerating fail_msg; then reuse the resolved object — never re-select with a bare
  `| first`). Zero and multiple are both hand-off failures. Declared specs must be mutually
  distinguishable (e.g. distinct identifiers).
- The declared CONFIG contract (post-merge `config.*`) is validated in ONE place where `config` is
  in scope — the role's `tasks/validate.yml`, run by the
  local v3.1.0 loader's `INIT | Validating Merged Configuration` hook. Version numbering
  verifies that the pinned framework loader is v3.3.0; its hook was not byte-inspected.
  This validation must **never** use `meta/argument_specs.yml` (it is structurally blind
  to the merged `config`; see §8).
- Guards carry a negative proof: deliberately wrong input fails on the intended assert
  while sibling specifications still pass.

## 4c. Mutation safety — SEEDED (2026-07-15)

- A component that MUTATES a declared resource carries a **state-aware safety assert BEFORE
  the first mutation** — the destructive analog of the §4b read-only guard. It refuses
  to clobber a resource that does not match the managed layout, recognizing an
  already-managed target by a **declared convention** such as an NTFS volume label,
  NEVER by size or enumeration number. Blank/RAW, already-ours, and positively
  recognized unformatted states proceed; a foreign/occupied state refuses loudly.
- **Named exception (Director, 2026-07-31): pinned shared `windows_disk_manager`.** It
  brings declared disks online and writable before classification and accumulates
  `__resolved_disks__` with `set_fact`. Its attachment guard resolves each declared
  `unique_id` to exactly one match; its later classifier repeats selection and uses `| first`.
  Its foreign-layout assert still precedes initialization, partitioning, and formatting.
  This exception does not weaken the general rules for roles authored here.

## 4d. Role scope — the application boundary — RATIFIED (Director, 2026-07-31)

- One role owns one installable application or one coherent capability. A second
  application is a second role, never a second task file; playbooks compose roles, and
  roles do not nest. Deployment co-location, operating mode, and shared accounts do not
  widen this boundary.
- Each application role is functionally independent: the platform disk role plus that
  one application role produces its complete correct result, and several application
  roles converge to the same result as when run individually. Each role therefore
  ensures its prerequisites idempotently; an ordered prerequisite-only role would
  reintroduce the forbidden dependency.
- **RATIFIED (Director, 2026-07-31):** When independent roles duplicate prerequisite
  logic, prove the second occurrence reports `changed=false` in the same convergence
  run, identified by its `TASK [<role> : ...]` prefix; a later whole-play
  `changed=0` run does not prove per-task idempotency.

## 4e. Role scope — the identity boundary — RATIFIED (Director, 2026-07-31)

- A role consumes ambient credentials and performs no identity transition. Credential
  acquisition belongs to the caller; document that the ambient identity itself holds
  each required grant, because assuming another identity couples the role to one caller
  shape.
- Never widen a grant for a module's convenience lookup; use its documented
  narrow-permission option.
- **RATIFIED (Director, 2026-07-31):** Define an account shared by independent roles
  once at play level and map the whole value into each role namespace. Do not restate
  it per role or use a YAML anchor; document that extra-vars can still replace an
  entire role dictionary, so this invariant is structural rather than enforced.

## 5. Windows conventions — SEEDED (first Windows role; ratify via research per cycle)

- Transport: **SSH** (org standard; key auth, one transport story across the fleet).
  `ansible_shell_type: powershell`; target's OpenSSH `DefaultShell` = PowerShell.
- `become: false` at play level (framework chassis `become=sudo` is POSIX-only;
  built-in administrator over SSH is already elevated). Revisit for least-privilege
  runs (runas) when a non-admin service account is introduced — TBD.
- **RATIFIED (Director, 2026-08-04) — supersedes the 2026-07-31 rule:** declare
  connection settings PER GROUP and give the controller its own inventory host; do not
  repeat the shell type per task. Windows connection vars on `all` reach the controller,
  because a delegated task resolves connection vars from the delegate's own var context
  and an implicit localhost inherits `all`. So: Windows vars on the Windows group, plus
  an explicit `localhost` carrying `ansible_connection: local`,
  `ansible_shell_type: 'sh'` and `ansible_python_interpreter: "{{ ansible_playbook_python }}"`.
  The interpreter pin is mandatory, not decorative — an inventory-defined localhost is no
  longer the implicit localhost and loses its automatic interpreter, so discovery would
  pick the system interpreter, which carries none of the controller-side SDKs. A task-level
  `vars: { ansible_shell_type: ... }` is then reserved for a delegate that genuinely differs
  from its inventory declaration.
  Evidence for the leak (verified on core 2.21.2 by inspecting `ansible_delegated_vars`
  and `-vvv` payloads): without a controller declaration the delegated context resolves
  `ansible_shell_type=powershell` and `ansible_user=administrator`, and controller payloads
  are built by the PowerShell shell plugin — `powershell -EncodedCommand`, module staged to
  a literal `\path\with\backslashes\%TEMP%\ansible-tmp-…\AnsiballZ_*.ps1`. Where a
  PowerShell binary happens to exist on the controller, the task reports success while
  writing that garbage into the working directory and never cleaning it up.
- Windows modules from `ansible.windows` (fallback `community.windows`); never invoke
  raw PowerShell where a module exists — use the proposed escape-hatch rule below.
- Loader Windows gaps are TD-001 workarounds in the playbook, not role hacks — see
  `docs/TECH-DEBT.md`.
- **RATIFIED (Director, 2026-07-31):** `ansible.windows.win_reg_stat` with `name:`
  returns `exists: false` for both an absent key and an absent property. To distinguish
  them, read the key without `name:` and test
  `'<Prop>' in result.properties and result.properties.<Prop>.value == ...`; this was
  verified in module source, and Jinja `and` short-circuits the absent-property access.
- **RATIFIED (Director, 2026-07-31):** Verify Windows ACLs by set equality over
  explicit, non-inherited ACEs: require exactly the declared ACEs and report inherited
  ACEs separately. Never assert a total ACE count or use a containment check, which
  permits undeclared grants.
- **RATIFIED (Director, 2026-07-31):** When asserting materialized
  `FileSystemRights`, expect `ReadAndExecute, Synchronize` for a declared
  `win_acl` right of `ReadAndExecute`; Windows generic mapping adds `Synchronize`, so
  do not change the declared right to match the observed string.
- **RATIFIED (2026-07-15) — required per-target
  inputs live in the `<role>:` override dict, consumed via `config`.** Environment-
  specific inputs the role cannot default (for example, `server_address` for an
  application or `disks[].unique_id` for `windows_disk_manager`) are declared inside
  the corresponding `<role>:` override dict and read from that role's `config`, matching the framework/wazuh
  idiom and the loader's `defaults -> overlays -> <role> override -> config` merge.
  Only `ENV`/`state` stay top-level (loader-level). NOTE: a `-e '{"<role>":{...}}'`
  override REPLACES the whole dict, so co-locate loader-read keys (`temp_dir`) with any
  `-e`/override-provided keys, and any override must re-state them. The README documents
  these as merged config, not top-level vars.
- **PROPOSED:** never `set_fact` the name `ansible_facts` — the resulting
  set_fact variable shadows the live facts store and silently hides every later
  facts module's results (verified 2026-07-15: `win_disk_facts` results were invisible until
  the TD-001 seed was rewritten to `packages: {} / cacheable: true`).
- **PROPOSED — the escape-hatch policy.** Native module FIRST, always. Where no module exists:
  1. `ansible.windows.win_command` in **`argv` form** is the sanctioned escape hatch
     (each element auto-quoted per Win32 rules — spaced paths are a non-issue; no shell
     parsing surface).
  2. `win_shell` ONLY for genuine shell semantics — e.g. a PowerShell **cmdlet**
     (`Get-Service`), pipes, redirects. Never for plain .exe invocation.
  3. Idempotency: `creates:`/`removes:` ONLY when the marker reliably represents
     **completed** desired state. An artifact the command creates EARLY in its run does
     NOT qualify — a midway failure leaves it behind and every later run silently
     false-converges. Where no reliable completion file exists, use the
     **probe-gates-actor idiom**: a read-only registered probe
     (`changed_when: false`, `failed_when: false` — nonzero rc IS the signal, not an
     error) gating the mutating command through `when:`.
  4. No `chdir` when the tool has no working-directory requirement; invoke by absolute
     path. No asserts on undocumented/localizable stdout — rc + a functional probe are
     the contract.
- **RATIFIED (Director 2026-07-16) — embedded PowerShell follows OTBS.** Any
  multi-statement PowerShell inside a `win_shell` block scalar uses One True Brace Style:
  opening brace on the statement line; cuddled `} elseif (...) {` / `} else {`; multi-statement
  bodies on their own indented lines (4-space); NO semicolon statement-chaining; blank lines
  between logical sections. Idiomatic one-line pipeline filter blocks
  (`Where-Object { ... }`) stay inline — OTBS governs control statements. First applied:
  a relocation probe and binding on later embedded scripts.
- **RATIFIED (M, 2026-07-17) — the native-module template for `win_shell` §8 escape hatches.**
  Every mutating `win_shell` block that stands in for a missing native module MUST act like one:
  1. `$ErrorActionPreference = 'Stop'` is the FIRST statement (a mid-script non-terminating error
     must not pass silently).
  2. Inputs arrive via `environment:` (env-passing), NEVER Jinja-interpolated into the PowerShell
     source (`'{{ x }}'`) — env-passing removes an injection + `split_args` surface. Architectural
     constants are defined ONCE in the
     task file's `vars:` block and env-passed, not duplicated per block.
  3. Any external resource (a `SqlConnection`) is opened inside `try { } finally { <close-only> }`
     — the `finally` closes and does nothing else (no `catch`, no swallow); intentional
     fail-closed `throw`s stay inside `try` before the finally.
  4. Idempotency by a normalized compare → mutate-on-diff → **re-acquire-and-verify** → deterministic
     `changed`/`nochange` (or a read-only probe with `changed_when: false`), never blind mutation.
  5. Embedded PowerShell follows OTBS (above).
- **RATIFIED 2026-07-17 — never put a backslash immediately before a closing quote
  (`\'` / `\"`) in `win_shell`/`win_command` free-form; enforced by an automated gate.** Ansible parses
  the free-form module arg with `split_args`, which honors `\` as an escape **even inside single quotes**.
  A literal backslash right before a closing quote — `Replace('/','\')`, `'C:\Build\stage\'`, `'C:\'` —
  escapes the quote, unbalances the parser, and fails the task at **LOAD time**
  (`failed at splitting arguments…`). Interior backslashes are fine;
  only backslash-adjacent-to-a-closing-quote breaks. **RULE:** build such strings with `[char]92`
  (`$dir.TrimEnd([char]92) + [char]92`) and never end a quoted literal with `\`. **GATE:**
  `scripts/check-winshell-splitargs.py` (run with the ansible-core venv python) fails on any
  `split_args` error OR any backslash-before-quote across every `win_shell`/`win_command` block — this
  is the ONLY static check that catches the class: yamllint, ansible-lint, AND
  `ansible-playbook --syntax-check` all pass an unbalanced-`\'` regression; a measured production
  escape established the failure mode on 2026-07-17. Part of the standard gate now.
- **RATIFIED (Director, 2026-08-06) — treat `win_*_info` results as list-shaped contracts.**
  Default list fields with `| default([])`, prove cardinality before `[0]` indexing,
  and quantify over all items. An absent key must neither error nor false-pass, and a
  healthy first item must not mask an unhealthy later item. Derive shapes from module
  source; item fields must not be read as top-level fields.
- **SEEDED (Director, 2026-07-16) — Users browse-access ACL
  hygiene.** Role-created directories INTENDED FOR INTERACTIVE ADMINISTRATION/BROWSING,
  under an explicitly documented trust model ("all interactive users are admins"), get an
  explicit `BUILTIN\Users` ReadAndExecute grant (`win_acl`, allow,
  `ContainerInherit, ObjectInherit`) co-located with their creation. WHY: an unreadable
  folder makes Explorer offer "Continue", which stamps the browsing admin's PERSONAL ACE
  onto the ACL — stale/orphaned SIDs after they depart. Explicit, never inherited-by-luck
  (format-default root ACLs evaporate under hardening). EXCLUDED BY DEFAULT: secrets,
  private service data, and product-managed ACL boundaries. An explicitly declared
  application data directory may be granted a reviewed exception.

## 6. Controller & toolchain — SEEDED

- pipx-installed `ansible-core` pinned to the framework's supported range
  (currently 2.21.x), plus `ansible-lint`, `yamllint`. Collections pinned:
  `ansible.windows`, `community.windows`.
- **Lint from the composed tree** (proven 2026-07-15): the playbook's role
  resolves only inside the composed framework checkout, so `ansible-lint` runs from
  `.compose/ansible-framework/` (which also supplies the chassis `.ansible-lint`
  profile). Repo-side `ansible-lint <playbook>` fails `syntax-check` by design — do
  not "fix" that by vendoring a roles_path shim without a ratified rule.
- SSH multiplexing is isolated per-repo (`.compose/.cp`, pre-cleaned every run) —
  stale ControlMaster sockets from interrupted or killed runs hang plays silently
  (proven 2026-07-15).

## 7. Commits & process — SEEDED

- Conventional Commits, scope = role name or `framework` (framework CI enforces
  upstream; this repo follows the same format).
- Build changes remain small and independently verifiable; style-rule ratifications are
  recorded here with their decision dates.
- **RATIFIED (Director, 2026-07-31):** A repository contract states which roles the
  repository carries and why that decomposition is correct; a bare role count makes a
  structural premise unreviewable.

### Engineering register — 2026-08-10

- **RATIFIED (Director, 2026-08-10):** Changes to a default-deny file allowlist must
  prove bidirectional set equality between allowed and tracked files, prove allowance
  entries contain no glob metacharacters, and probe an ignored sentinel under every
  remaining directory-spine entry.
- **RATIFIED (Director, 2026-08-10):** Claims about configuration at a pinned revision
  require direct inspection at that revision or execution against it; ancestry alone is
  insufficient.
- **RATIFIED (Director, 2026-08-10):** Advertised run commands must execute to convergence
  as written: declare inputs at their point of use, express paths from the tool's resolution
  directory, and name prerequisites beside the command.

## 8. Open questions (moved to RATIFIED/rule sections as cycles decide them)

- ~~`win_shell`/`win_command` escape-hatch policy and idempotency guards~~ — **DECIDED
  (2026-07-16):** moved to the proposed rule in §5; pending Director
  ratification.
- Handler usage & service-restart conventions on Windows.
- Molecule (or equivalent) test story for Windows roles — framework roles ship
  `molecule/`; no Windows driver decision yet.
- Argument specs (`meta/argument_specs.yml`) — **DECIDED (V, 2026-07-15): NOT adopted for
  enforcement.** The auto-inserted arg-spec validator runs BEFORE the v3 loader builds the merged
  `config` (verified empirically), so it is structurally blind to `config.*` and only duplicates the
  loader's ENV/state assert. Merged-config validation lives in the role's
  `tasks/validate.yml`; see §4b.
  `argument_specs` is
  permissible only as description-only documentation of the `<role>:` dict shape. _(superseded note)_ wazuh roles use them; python3_pip's
  meta shape TBD against it.
- Secrets handling for Windows (no vault usage yet in this repo).
