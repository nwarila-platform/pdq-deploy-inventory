# Tech debt register

## TD-001 — CLOSED — pinned v3 loader supports Windows

- **Recorded:** 2026-07-15. **Corrected:** 2026-08-10.
- **Original premise:** the shared loader needed Windows support before the two local v3.1.0
  copies and their playbook compatibility settings could be retired.
- **Correction:** the pinned framework loader v3.3.0 is Windows-aware; no future framework
  version is needed to supply that support.
- **Result:** the remaining work is the local-loader refresh and deployment proof tracked
  only in TD-003. That proof determines which compatibility settings can be retired.

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

## TD-003 — local v3.1.0 loader differs from framework v3.3.0

- **Recorded:** 2026-07-15. **Version comparison verified:** 2026-08-10.
- **What:** both local role loaders are v3.1.0 and provide the generic
  `INIT | Validating Merged Configuration` hook. The pinned framework loader is v3.3.0.
- **Debt:** the local copies are not byte-identical to the pinned shared loader.
- **Rollout:** review the intervening generic loader changes, refresh both role copies
  atomically from the pin, verify byte equality, and run the deployment-level proof that
  is required for a playbook/loader change.
- **Exit criteria:** both local loaders match the pinned framework loader and retain the
  merged-config validation contract.

## TD-005 — v3 loader exposes merged secret-bearing config at verbose output

- **Recorded and proven:** 2026-07-28.
- **What:** the loader persists each merged `<role>_running` dictionary with `set_fact`.
  The playbook maps `pdq_service_account.password` into both
  `pdq_inventory.service_account.password` and `pdq_deploy.service_account.password`, so
  verbose runs can print the merged values.
- **Scope:** every secret-bearing role using this loader. Default-verbosity runs did not
  print the sentinel value in the 2026-07-28 proof, and consuming tasks use `no_log`.
- **Existing mitigation:** provide secrets through a protected extra-vars file or vault,
  never as command-line literals.
- **Fix:** add `no_log: true` to the shared loader's override-merge task under the
  loader-change policy, then refresh both local copies from an updated framework pin.

## TD-006 — framework pin is a minimal fix commit off the old pin, not a released mainline

- **Recorded:** 2026-08-23.
- **What:** `.framework-pin` points at `9fc6cba`, the previous pin `24a8ec74` plus only the
  `windows_disk_manager` adopted-drive-letter fix (cherry-picked onto that base). The canonical
  fix is PR #68 on the framework's `main`; `9fc6cba` lives on the branch
  `windisk-adopted-letter-on-pin`.
- **Debt:** the pin is deliberately off the mainline release track — a minimal, tested delta chosen
  so enabling OS-drive replacement did not also pull in unrelated `main` changes (RedHat/Rocky
  hardening) that our Windows composition has not exercised.
- **Exit criteria:** once PR #68 merges and the framework releases, re-pin to a mainline commit that
  includes the fix and verify the composition still converges and stays idempotent.
