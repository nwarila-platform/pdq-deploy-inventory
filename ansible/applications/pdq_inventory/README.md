# `pdq_inventory` role

Installs PDQ Inventory at a pinned version and brings it up as an all-in-one **Central Server** on
Windows. In one converge it installs the product, applies the licence, runs the background service
under the shared PDQ service account, places the database on its dedicated drive, sets Central
Server mode and the console port, applies the product's preferences, reconciles the pinned
variables and the owned collections, seeds the per-user console defaults, authorises the console
users, chooses the event-log severities, and records the registration that would otherwise stop
the first console with a popup. PDQ Inventory is a scanner, so — unlike `pdq_deploy` — it
publishes **no package repository and no network share**.

Both declarations are complete. The variable map is the whole set: a converge adds what is
missing, corrects what differs, removes what the map does not name, and proves each removal from
a fresh export. A collection is stated as its exported XML, imported only on difference and
proven by re-export; every top-level collection the role does not own is removed with its
children, except the product's own built-in furniture and the shipped Collection Library, whose
rows are compared identity by identity before and after so a converge that touched them fails.

Everything moves through the controller: it fetches each artifact from S3 and hands the installer
to the target, so the guest never receives cloud credentials. The installer is verified against
its pinned SHA-256 on the guest before execution, the licence is verified against its pinned
SHA-256 before use, and the in-memory service-account password is rejected if it is empty.

> **Scope: domainless lab profile.** The defaults target a standalone Windows host with a local
> service account and local console users; a domain service account, group-based console
> authorisation, and RBAC hardening await a directory service.

## Composition and prerequisites

The role is overlaid into a version-pinned checkout of `nwarila-platform/ansible-framework` at run
time; it is not run directly from this repository. The shipped `ansible/playbooks/pdq-aws.yml`
composes `windows_disk_manager`, `pdq_deploy`, and `pdq_inventory` onto one host.

`windows_disk_manager` plus `pdq_inventory` alone is a supported composition: it produces a
complete Inventory Central Server without `pdq_deploy`. Both application roles share ONE Background
Service User (`svc-pdq`), so each ensures it idempotently and neither strips the other's work. The
Windows service password cannot be read back, so each role reasserts that credential on every
converge and honestly reports one expected change.

The target must be Windows Server with the `ansible.windows` and `community.windows` modules the
role uses. The controller's Ansible environment needs the `amazon.aws` collection with supported
`boto3`/`botocore` for the S3 fetch.

## What the caller supplies

Required deployment-specific inputs carry an account id or change with every version and every
site, so the playbook states them where a reader can see them: the installer (bucket, four-part
version, digest), the licence (bucket, object, digest, and the email it was issued to), the
service-account password (bucket and object), and the database drive letter. The caller may also
replace the default all-addresses listener with explicit addresses. `tasks/validate.yml` enforces
these inputs on the controller before anything touches the guest.

## Configuration

Universally safe values — product identity, install staging, console access, the console port, and
the declared preference surface — live in `defaults/main.yml`. Preferences are organised as the
console's Preferences window is: a map of pages, each holding its settings under readable labels.
The values are the product's own measured defaults except where the file identifies a deliberate
data-egress choice. The surface is declared in full so a vendor changing a default surfaces as a
reported change rather than silent drift.

## State

- `present` (default) — install and configure to the declared state.
- `absent` — uninstall the product, reading the ProductCode from the machine.
- `clean` — remove only the staged-installer cache. The product, its database, and its
  configuration are untouched.

## Design invariants

- **All-in-one Central Server only.** PDQ Deploy and Inventory integrate only co-located, in the
  same operating mode, under one service account; the mode is written literally, never offered.
- **No package repository.** Inventory scans; it does not deploy, so it publishes no share.
- The console port defaults to the product's own **7337**.

## First-class PowerShell

Guest-side logic that a task cannot express cleanly is a first-class PowerShell script, developed
and Pester-tested once under `scripts/` and materialized into the role by
`scripts/materialize-role-scripts.sh` (the role tracks only the `.ps1.stub` markers). The role uses
`Get-InstalledSoftware.ps1`, `Set-PdqSetting.ps1`, `Set-PdqVariable.ps1`,
`Remove-PdqVariable.ps1`, and `Set-PdqRegistration.ps1`, all shared with `pdq_deploy`, plus
Inventory's own `Set-PdqCollection.ps1` / `Remove-PdqCollection.ps1` for the collections.

## Verification

```bash
export PATH="$PATH:/root/.local/bin"
yamllint -c .yamllint.yml ansible
scripts/materialize-role-scripts.sh
(cd .compose/ansible-framework && ansible-lint applications/pdq_inventory)
# Pester runs in CI (the powershell-template pester-matrix), one leg per scripts/ pair.
```
