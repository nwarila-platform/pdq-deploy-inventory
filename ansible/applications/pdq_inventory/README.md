# `pdq_inventory` role

Installs PDQ Inventory at a pinned version and brings it up as an all-in-one **Central Server** on
Windows. In one converge it installs the product, applies the licence, runs the background service
under the shared PDQ service account, reconciles the complete credential store,
places the database on its dedicated drive, sets Central Server mode and the console port, applies
the product's preferences, reconciles the pinned variables and the owned collections, seeds the
per-user console defaults, authorises the console users, chooses the event-log severities, and
records the registration that would otherwise stop the first console with a popup. PDQ Inventory is
a scanner, so — unlike `pdq_deploy` — it publishes **no package repository and no network share**.

The credential list and variable map are complete declarations: a converge adds what is missing,
corrects what differs, removes what the declaration does not name, and proves the resulting set.
A collection is stated as its exported XML, imported only on difference and
proven by re-export; every top-level collection the role does not own is removed with its
children, except the product's own built-in furniture and the shipped Collection Library, whose
rows are compared identity by identity before and after so a converge that touched them fails.

Everything moves through the controller: it fetches each artifact from S3 and hands the installer
to the target, so the guest never receives cloud credentials. The installer is verified against
its pinned SHA-256 on the guest before execution, the licence is verified against its pinned
SHA-256 before use, and the in-memory service-account password is rejected if it is empty.

## Domain, credentials and directory sync

The host is domain-joined, but the background service stays under a **local** account — the one
`service_account` names, `.\svc-pdq` by default, shared with `pdq_deploy`. `credentials` is the
complete list of rows Inventory holds, each naming the account, carrying the password that opens
it, and — for exactly one — claiming `is_default`. The flag is stated because the product marks
whichever row was written last as its default; a list that said nothing would never settle.
Inventory holds one domain class account per managed OU. Each container binds as its class account
and gives computers added from that OU the same row as their scan user. The local service account
is also a credential and is the default fallback outside those OUs and for the console itself.
Deploy takes a target's scan credential from this store.

The list is authoritative: a row it does not name is removed. An empty list on a populated console
removes every Inventory credential it scans with.

`directory_sync` is the computer sync: the realm, the account the sync binds as, and the
containers — each a distinguished name plus the two flags the product stores. The product offers no
command line for any of it, so `Set-PdqSyncContainer.ps1` writes the declaration to the product's
own store, resolves each container's GUID from the directory, starts a sync, and reads the
product's own verdict back; a container the product could not read fails the run by name. The
declaration is complete: a container it does not name is removed. Under `delete_mode: FullSync`
that also means a declaration that names containers but includes none would empty the database on
the first sync, which `tasks/validate.yml` refuses.

The bind account is a **name** into `credentials`, never a password, at every level: the role hands
the script the credential list and the script resolves each secret by the same username the
product resolves its credential row by. A container may name its own bind account and its own
realm, so a second directory is one more container rather than a second declaration; the role owns
the product's domain rows — one per realm the containers name, pointing at the account its
containers bind as, never at the console user. `insecure` opts the directory read down to plain
LDAP on 389 and is stated in the open when a directory cannot serve LDAPS.

The three class accounts are created by the separate elevated `pdq_ad_config` role. Nothing in
this role names a directory, an account or a cloud account; those facts are the caller's.

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
service-account password (bucket and object), each credential the product authenticates with
(account, password, and which one is the default), the directory sync (realm, the bind account's
name, and the containers), and the database drive letter. The caller may also replace the default
all-addresses listener with explicit addresses. `tasks/validate.yml` enforces
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
- **A local service, authoritative credentials.** The service logs on as a local account, which may
  also be Inventory's default fallback credential; every directory bind is a name into the list.
- The console port defaults to the product's own **7337**.

## First-class PowerShell

Guest-side logic that a task cannot express cleanly is a first-class PowerShell script, developed
and Pester-tested once under `scripts/` and materialized into the role by
`scripts/materialize-role-scripts.sh` (the role tracks only the `.ps1.stub` markers). The role uses
`Get-InstalledSoftware.ps1`, `Set-PdqSetting.ps1`, `Set-PdqVariable.ps1`,
`Remove-PdqVariable.ps1`, `Set-PdqCredential.ps1`, and `Set-PdqRegistration.ps1`, all shared with
`pdq_deploy`, plus Inventory's own
`Set-PdqCollection.ps1` / `Remove-PdqCollection.ps1` for the collections and
`Set-PdqSyncContainer.ps1` for the directory sync.

## Verification

```bash
export PATH="$PATH:/root/.local/bin"
yamllint -c .yamllint.yml ansible
scripts/materialize-role-scripts.sh
(cd .compose/ansible-framework && ansible-lint applications/pdq_inventory)
# Pester runs in CI (the powershell-template pester-matrix), one leg per scripts/ pair.
```
