# Tech debt register

## TD-001 — CLOSED — pinned v3 loader supports Windows

- **Recorded:** 2026-07-15. **Corrected:** 2026-08-10.
- **Original premise:** the shared loader needed Windows support before the two local v3.1.0
  copies and their playbook compatibility settings could be retired.
- **Correction:** the pinned framework loader v3.3.0 is Windows-aware; no future framework
  version is needed to supply that support.
- **Result:** the local-loader refresh was completed under TD-003. No loader Windows-support debt
  remains.

## TD-002 — CLOSED — chassis lint treatment of region banners

- **Recorded:** 2026-07-15. **Closed:** 2026-08-10.
- **Original issue:** the chassis treated the established `#region`/`#endregion` banners
  as fatal `yaml[comments]` violations, requiring a command-line warning override.
- **Closure evidence (2026-08-10):** the framework `.ansible-lint` at pinned commit
  `e8b2b95` directly lists `yaml[comments]` in `warn_list`, with the region rationale.
  The closing framework commit `5f5cae81…` is an ancestor of that pin. After clean
  per-role overlay comparisons, plain composed-tree
  `ansible-lint applications/pdq_inventory applications/pdq_deploy` exited 0 without a
  warning override; banner findings were warnings only.
- **Result:** no repository-side workaround remains necessary.

## TD-003 — CLOSED — local loaders match framework v3.3.0

- **Recorded:** 2026-07-15. **Closed:** 2026-08-12.
- **Original issue:** both local roles carried a v3.1.0 loader that differed from the framework's
  v3.3.0 loader.
- **Closure evidence:** commit `954f3a5` adopted the framework loader verbatim in both roles. The
  current files declare v3.3.0, are byte-identical to each other and to the loader at the framework
  base commit, and retain `INIT | Validating Merged Configuration`.
- **Result:** the local loader fork and its Windows package-fact failure are resolved.

## TD-005 — CLOSED — merged configuration is redacted from verbose output

- **Recorded:** 2026-07-28. **Closed:** 2026-08-12.
- **Original issue:** the loader's `set_fact` tasks could print the merged
  `<role>_running` dictionary, including caller-supplied secrets, at verbose output.
- **Closure evidence:** the v3.3.0 loader sets `no_log: true` on all three tasks that seed or merge
  the running configuration: defaults, OS overlays, and caller overrides. Both local loaders carry
  those guards and remain byte-identical.
- **Result:** ordinary verbose runs no longer expose the merged dictionaries; consuming secret
  tasks retain their own `no_log` guards.

## TD-006 — CLOSED — framework pin is a released mainline commit

- **Recorded:** 2026-08-23. **Closed:** 2026-08-24.
- **Original issue:** `.framework-pin` pointed at `9fc6cba`, a single commit above the previous
  pin carrying only the `windows_disk_manager` adopted-drive-letter fix, deliberately off the
  mainline release track.
- **Closure evidence:** the pin is now `d19e6d4`, released `v0.1.6`, which contains that fix. The
  composition converged against it and the second converge reported only the two expected
  credential changes, so the exit criteria are met.

## TD-007 — CLOSED 2026-09-18 — collection import is batched inside the script

- **Recorded:** 2026-08-31.
- **Issue:** `PROCESS | Import The Declared Collections` loops on the Ansible side, so each of the
  17 declared definitions is its own task, with its own SSH round trips, its own `become: runas`
  batch logon, and its own transfer and compile of the 444-line `Set-PdqCollection.ps1`.
  `Get-CollectionText` then exports one collection at a time by name, so answering "what does the
  product hold?" costs 17 command-line launches.
- **Measured** (run `33283329062`, four converges of one host): 816 s for the first converge and
  342 s, 334 s and 355 s for the three that follow — 30.8 minutes of the deploy, and the largest
  single consumer in it. A converged host that writes nothing still spends 20.1 s per collection.
- **Cause, isolated within the same run:** `PROCESS | Import The Pinned Variables` does the same
  kind of work in ONE task — 45 variables, 47 command-line launches, 331 s, so 7.0 s per launch.
  The collection loop bills 17.3 s per launch. The ~13 s difference is per-task overhead that the
  variable path pays once and the collection path pays 17 times. The changed path corroborates:
  three launches per collection predicts 2.8 + 3 × 17.3 ≈ 55 s against 48.0 s measured.
- **Correction:** `Set-PdqCollection.ps1` now owns the complete definition array. The Inventory
  role invokes it once, with no Ansible loop; one `ExportCollections` call carries every declared
  name as a separate argument after `-Name` and writes one file per collection into a staging
  directory, only differing definitions are imported, and the complete set is read back after
  mutation. This is the measured `string+` invocation required by Inventory 20.1.8; a single
  comma-joined argument is treated as one collection name. The result object's `applied`,
  `removed`, `unchanged`, `ignored`, and `survivors` arrays preserve the names formerly supplied
  by loop labels.
- **Authoritative sets:** the collection and variable Set scripts now also own removal, including
  empty declarations. The standalone Remove scripts, specs, stubs, role tasks, and allowlist
  entries were retired. Built-in collections and every Collection Library row retain the former
  pruner's exact protection.
- **Closure evidence:** the collection spec proves a converged plural declaration makes exactly
  one `ExportCollections` launch with each name as a separate `string+` argument. The script
  creates the staging directory before that launch, requires one file per requested collection,
  and correlates each file by its embedded XML `Name` rather than by its filename. The spec also
  proves exit 3 is the valid empty-product answer, while statuses 1, 2 and 4 stop before import or
  prune. Comma-bearing names remain refused because comma is per-name selection syntax; that
  addressability rule is independent of batching multiple names as separate arguments. The
  mutation cases prove only differences are imported, undeclared entries are removed, built-ins
  and the library survive, failures name what did not settle, and read-back is batched. The
  focused collection spec passed all 20 tests on 2026-09-18. The deployment workflow's drift,
  export-equality, and repaired-state gates are enabled again, so its next live run must
  independently prove the authoritative repair and following steady converge.
- **Exit criteria met:** one task applies the collection set; one command-line launch reads all
  declared collections on a converged host; the converged script reports `changed=0`; every changed
  collection remains named in the result.

## TD-008 — OPEN — no role installs the AWS PowerShell module the repository sync reads through

- **Recorded:** 2026-08-31. **Restated:** 2026-09-25.
- **Issue:** the repository sync reads the bucket through an AWS PowerShell module —
  `AWS.Tools.S3`, or the monolithic `AWSPowerShell` that stock Windows Server 2019 carries
  instead — and nothing in this repository installs either. The deployment relies on the base
  image supplying one.
- **Why it is debt rather than a defect today:** the images in use do supply one, so the
  deployment works. The dependency is undeclared, unpinned and unproven — a base image change
  removes it silently, and the first symptom is a converge that fails at its last step.
- **Also unpinned:** the version. Everything else this deployment installs is pinned to an exact
  build with a digest; the module is whatever the image happens to carry.
- **Correction:** a small role in the framework that installs a pinned version of the module, so
  a host declares what it depends on instead of inheriting it. It belongs in the framework rather
  than here: every repository whose hosts read S3 natively has the same dependency.
- **Exit criteria:** a converged host holds a declared, pinned AWS PowerShell module version; a
  base image without one converges to the same state; and nothing reads the bucket without the
  role that guarantees the module having run.
