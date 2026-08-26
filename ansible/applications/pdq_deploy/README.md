# `pdq_deploy` role

Installs PDQ Deploy at a pinned version and brings it up as an all-in-one **Central Server** on
Windows. In one converge it installs the product, applies the licence, ensures the shared PDQ
service account and records its credential with the product, places the database on its dedicated
drive, creates the package repository on a second drive and enforces its directory permissions,
publishes it as an encrypted read-only network share, writes the script that fills it, sets
Central Server mode and the console port, applies the product preferences, reconciles the pinned
variables and the declared packages, seeds the per-user console defaults, authorises the console
users, chooses the event-log
severities and service-manager behaviour, and records the registration that would otherwise stop
the first console with a popup.

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

`windows_disk_manager` plus `pdq_deploy` alone is a supported composition: it produces a complete
Deploy Central Server without `pdq_inventory`. Both application roles share ONE Background Service
User (`svc-pdq`), so each ensures it idempotently and neither strips the other's work. The Windows
service password cannot be read back, so each role reasserts that credential on every converge and
honestly reports one expected change.

The target must be Windows Server with the `ansible.windows` and `community.windows` modules the
role uses. The controller's Ansible environment needs the `amazon.aws` collection with supported
`boto3`/`botocore` for the S3 fetch.

## What the caller supplies

Required deployment-specific inputs carry an account id or change with every version and every
site, so the playbook states them where a reader can see them: the installer (bucket, four-part
version, digest), the licence (bucket, object, digest, and the email it was issued to), the
service-account password (bucket and object), one drive letter each for the database and
repository, and the repository's own bucket and region. The caller may also replace the default all-addresses listener with explicit addresses.
`tasks/validate.yml` enforces these inputs on the controller before anything touches the guest.

## Configuration

Universally safe values — product identity, install staging, console access, the console port, the
repository directory and share name, and the declared preference surface — live in
`defaults/main.yml`.
Preferences are organised as the console's Preferences window is: a map of pages, each holding its
settings under readable labels. The values are the product's own measured defaults except where
the file identifies a deliberate data-egress choice. The surface is declared in full so a vendor
changing a default surfaces as a reported change rather than silent drift. The repository setting
is derived from the host and the share this role publishes, keeping the directory, share, and
product configuration aligned.

## Filling the repository

The repository holds the installers deployments copy to their targets. Those are vendor content,
not configuration: pinning each one here would make a converge the only way to publish software.
The role therefore ships the pull rather than performing it. `templates/Sync-Repository.cmd.j2` is
written as `Sync-Repository.cmd` in the root of the repository drive, carrying this host's bucket,
region and repository path, so an administrator runs it without knowing any of them. It sits one
level above the directory it fills so that it is neither an object the sync can act on nor a file
inside the network share.

The sync is additive — `aws s3 sync` without `--delete` — because the repository layout carries the
version in the path precisely so older versions stay on disk for a rollback.

The script is generated unconditionally; whether it can complete is a property of the host, not of
this role. It needs the AWS CLI installed, and it needs the host's instance profile to allow reads
on the bucket. It reports which of the two is missing rather than failing on the first object.

## Declared packages

`files/packages/` is the complete declaration: the product ends every converge holding exactly the
packages declared there and nothing else. Each `*.xml` is a package exported from the console and
committed unchanged, so the repository states the package rather than describing it.

A definition is imported only when the product does not hold it or holds it differently, and the
import is proved by exporting the package again, so a converged host writes nothing. Install steps
reference the pinned variables by name, which is why the packages are imported after them.

The variable declaration is complete in the same sense: the role adds what is missing, corrects
what differs, and removes every custom variable the map does not name, proving each removal from a
fresh export of the product's own store. A variable added by hand at the console is gone on the
next converge.

A package the product holds that no definition names is then removed, and the removal is proved by
listing the packages again. That is not something the caller switches on — a role that states an
end state and leaves strangers standing has not stated the end state. Read the same way, staging no
definitions declares that the product holds no packages, and the converge empties it.

Because the declaration is complete, a definition that never *arrived* — an overlay that skipped
`files/`, a file never allowlisted in `.gitignore`, a partial checkout — says exactly what a
definition deliberately withdrawn says: remove that package. The files alone cannot tell those
apart, so `defaults/main.yml` names the definitions the role expects under `packages:`, and the
converge stops before touching the host if what is on disk is not what is named. An empty
`packages:` list is how a caller states that the product holds none.

Adding a package is therefore three things: export it from the console into `files/packages/`,
allow that exact filename in `.gitignore` (which tracks nothing it has not been told about by
name), and name it in `packages:`.

## State

- `present` (default) — install and configure to the declared state.
- `absent` — uninstall the product, reading the ProductCode from the machine.
- `clean` — remove only the staged-installer cache. The product, its database, repository, and
  configuration are untouched.

## Design invariants

- **All-in-one Central Server only.** PDQ Deploy and Inventory integrate only co-located, in the
  same operating mode, under one service account; the mode is written literally, never offered.
- **One package repository and network share.** Deploy owns their directory, ACL, and share state
  on the caller-supplied repository drive.
- The console port defaults to the product's own **6336**.

## First-class PowerShell

Guest-side logic that a task cannot express cleanly is a first-class PowerShell script, developed
and Pester-tested once under `scripts/` and materialized into the role by
`scripts/materialize-role-scripts.sh` (the role tracks only the `.ps1.stub` markers). The role uses
`Get-InstalledSoftware.ps1`, `Set-PdqSetting.ps1`, `Set-PdqVariable.ps1`,
`Remove-PdqVariable.ps1`, and `Set-PdqRegistration.ps1`, all shared with `pdq_inventory`, plus
Deploy's own `Set-RepositoryAcl.ps1` for the package directory and `Set-PdqPackage.ps1` /
`Remove-PdqPackage.ps1` for the packages.

## Verification

```bash
export PATH="$PATH:/root/.local/bin"
yamllint -c .yamllint.yml ansible
scripts/materialize-role-scripts.sh
(cd .compose/ansible-framework && ansible-lint applications/pdq_deploy)
# Pester runs in CI (the powershell-template pester-matrix), one leg per scripts/ pair.
```
