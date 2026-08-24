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
