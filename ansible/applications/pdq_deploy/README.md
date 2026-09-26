# `pdq_deploy` role

Installs PDQ Deploy at a pinned version and brings it up as an all-in-one **Central Server** on
Windows. In one converge it installs the product, applies the licence, ensures the shared PDQ
service account and reconciles the complete credential store, places the
database on its dedicated drive, creates the package repository on a second drive and enforces its
directory permissions, publishes it as an encrypted read-only network share, fills it from the
application repository bucket, sets Central Server mode and the console port, applies the product
preferences, reconciles the pinned variables and the declared packages, seeds the per-user console
defaults, authorises the console users, chooses the event-log severities and service-manager
behaviour, and records the registration that would otherwise stop the first console with a popup.

The controller fetches the installer and licence from S3 and carries both to the target. The host
reads the application repository bucket itself through its instance profile. The installer is
verified against its pinned SHA-256 on the guest before execution, the licence is verified against
its pinned SHA-256 before use, and the in-memory service-account password is rejected if it is
empty.

## Domain and credentials

The host is domain-joined, but the background service stays under a **local** account — the one
`service_account` names, `.\svc-pdq` by default, shared with `pdq_inventory`. `credentials` is the
complete list of rows Deploy itself holds, each naming the account, carrying the password that
opens it, and — when any are declared — exactly one claiming `is_default`. The flag is stated
because the product marks whichever row was written last as its default; a list that said nothing
would never settle. Each product keeps its own credential store, but Deploy may hold none and take
a target's scan credential from Inventory at deployment time. Every credential declared here is
also admitted to the repository share, since a deployment fetches its installer over UNC as that
account.

The list is authoritative: a row it does not name is removed. An empty list on a populated console
removes every Deploy credential. Nothing in this role names a directory, an account or a cloud
account; those facts are the caller's.

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
service-account password (bucket and object), each credential the product authenticates to a
target with (account, password, and which one is the default), one drive letter each for the
database and repository, and the repository's own bucket and region. The caller may also replace the
default all-addresses listener with explicit addresses.
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
The role therefore mirrors the application repository bucket into it, and the host reads the
bucket itself, through its instance profile, rather than receiving gigabytes through the
controller.
The sync fetches objects through ten 8 MiB ranged requests at once, whichever module is installed.
A refresh can hold one temporary copy of every object it is refreshing at once, so the repository
volume needs free space for the objects being refreshed (a full refresh: the repository's size again).

The mirror is one scheduled task, `PDQ Repository Sync`, with no schedule of its own. It runs as
the Background Service User with its elevated token, logged on without a stored password. Each
converge starts it where the repository is prepared and waits for it as the installation's last
step, so a first fill that takes hours runs alongside the rest of the converge instead of ahead of
it. Each run writes one bounded Information outcome to the Application event log under source
`PDQ Repository Sync`, and each retried fetch writes a Warning there. A sync that fails writes an
Error outcome and fails the converge, naming its result and quoting that fresh event. A converge that
finds a sync already running waits for it to finish before starting its own, and fails at the
sync's own step if its run cannot start because the service account cannot log on. Task Scheduler
ends a run after 24 hours. Each of the converge's two waits is bounded by the same limit — one for
a run already in progress and one for its own — so a converge that meets an existing run can wait
about twice the limit. If no fresh outcome appears, the converge reports the task's last run result:
the sync either did not start or failed before it could report. A check run validates the task but
starts nothing.

An administrator starts the same task between deployments with `Sync-Repository.bat` —
right-click, "Run as administrator" — and a start while a sync is running is ignored, so run it
again once that sync has finished to pick up anything published since it began. The
launcher and the script the task runs live in `Sync-Repository\` at the root of the repository
drive: beside the repository rather than in it, so they are neither objects the sync can act on nor
files inside the network share, and under the repository's own permissions, because the volume root
lets any authenticated user modify what it holds.

The sync is deterministic: afterwards the repository holds what the bucket holds and nothing else.
The repository layout carries the version in the path so older versions stay addressable for a
rollback — in the bucket, which is the one place that decides what the repository contains. A file
the bucket does not carry is removed, including one placed here by hand, because a volume that
kept local-only files would drift away from every other host running the same deployment.

The sync needs an AWS PowerShell module on the host — `AWS.Tools.S3`, or the `AWSPowerShell` that
stock Windows Server 2019 carries instead — and the host's instance profile allowing reads on the
bucket. Nothing in this repository installs the module (TD-008 in `docs/TECH-DEBT.md`).

## Declared packages

`files/packages/` is the complete declaration: the product ends every converge holding exactly the
packages declared there and nothing else. A package's `<Path>` declares where it is filed. Each
`*.xml` starts with the console's export, so the repository states the package rather than
describing it; a nested target path is hand-written in the canonical spelling without the leading
`Packages\` that the export uses.

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

Two ids inside a definition belong to the console it was exported from rather than to the package:
the collection a condition gates on, and the scan profile a scan step runs. Both are resolved by
NAME on arrival and read back afterwards. A condition carries its collection's name as well as the
id, so the definition already says which collection it means; the role asks PDQ Inventory for that
collection's local id and writes it, because the import keeps the name and leaves the id null while
a deployment resolves membership by id alone — until it is written, every deployment of that
package stops before its first step with "Collection not found". A scan step carries only the
number, so the profile's name is declared in `scan_profiles:` by package name, and this console's
own id is written into the document before it is imported. A name that resolves to nothing stops
the converge, rather than importing a package that would fail at deployment time. A definition that
names a collection therefore makes PDQ Inventory a precondition for this role, which is why the
play converges Inventory first.

Adding a package is therefore three things: export it from the console into `files/packages/`,
allow that exact filename in `.gitignore` (which tracks nothing it has not been told about by
name), and name it in `packages:` — four, when it carries a scan step, which also names the
profile that step runs in `scan_profiles:`.

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
- **A local service, authoritative credentials.** The service logs on as a local account; Deploy's
  own credential list may be empty when deployments use Inventory scan credentials.
- The console port defaults to the product's own **6336**.

## First-class PowerShell

Guest-side logic that a task cannot express cleanly is a first-class PowerShell script, developed
and Pester-tested once under `scripts/` and materialized into the role by
`scripts/materialize-role-scripts.sh` (the role tracks only the `.ps1.stub` markers). The role uses
`Get-InstalledSoftware.ps1`, `Set-PdqSetting.ps1`, `Set-PdqVariable.ps1`,
`Set-PdqCredential.ps1`, and `Set-PdqRegistration.ps1`, all shared with `pdq_inventory`, plus
Deploy's own `Set-RepositoryAcl.ps1` for the package directory and `Set-PdqPackage.ps1` for the
complete package set.

## Verification

```bash
export PATH="$PATH:/root/.local/bin"
yamllint -c .yamllint.yml ansible
scripts/materialize-role-scripts.sh
(cd .compose/ansible-framework && ansible-lint applications/pdq_deploy)
# Pester runs in CI (the powershell-template pester-matrix), one leg per scripts/ pair.
```
