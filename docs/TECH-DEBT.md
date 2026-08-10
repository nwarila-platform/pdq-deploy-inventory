# Tech debt register

## TD-001 — ansible-framework v3 loader is not Windows-aware

- **Recorded:** 2026-07-15.
- **Where:** `ansible/applications/pdq_deploy/tasks/main.yml` and
  `ansible/applications/pdq_inventory/tasks/main.yml` use local loader v3.1.0.
- **Gaps:** the generic loader invokes POSIX-oriented package facts and temporary-file
  behavior. The Windows play also needs explicit fact gathering and `become: false`.
- **Workarounds:** `ansible/playbooks/pdq.yml` gathers facts, disables the loader temporary
  directory for both roles, seeds an empty package map without replacing `ansible_facts`,
  and disables privilege escalation. An extra-vars role dictionary replaces the playbook
  dictionary, so an override must restate `temp_dir: false`.
- **Proper fix:** add generic Windows support to the shared loader, validate it under the
  loader-change policy, advance `.framework-pin`, and remove the playbook workarounds.
- **Exit criteria:** the pinned framework loader supports Windows and both local loader
  copies can be replaced byte-for-byte without the workarounds.

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
