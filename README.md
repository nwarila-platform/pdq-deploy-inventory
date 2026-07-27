# pdq-deploy-inventory

A single-purpose `nwarila-platform` application repo that carries the **`pdq`** Ansible role —
a **PDQ Deploy & Inventory** all-in-one **Central Server** on Windows Server — plus its playbook
and inventory. It **composes** into a version-pinned checkout of `nwarila-platform/ansible-framework`
at execution time (never runs repo-side).

Structurally mirrors [`secure-wazuh`](../secure-wazuh) (repo hygiene, docs, strict cycle, AWS-PoC
model) with the Windows-specific lessons from [`windows-wsus`](../windows-wsus) folded in (SSH+PowerShell
transport, the v3.1 loader Windows workarounds, the 3-disk provisioning pattern via `windows_disk_manager`,
the `check-winshell-splitargs.py` gate, the `BUILTIN\Users` ACL convention, the P4.5 review discipline).

## What it deploys

One Windows Server, handed with **3 blank data disks**, configured end-to-end:

| Disk | Drive | Label | Holds |
|------|-------|-------|-------|
| 1 | E: | `PDQDEPLOY` | PDQ Deploy database |
| 2 | F: | `PDQINVENTORY` | PDQ Inventory database |
| 3 | G: | `PDQSHARE` | PDQ Deploy repository / App Share (install-source UNC share) |

PDQ Deploy **and** PDQ Inventory run on this one host in **Central Server** mode under a shared
Background Service User (the integration prerequisite) — client consoles connect on TCP **7337**.

## Layout

```
ansible/applications/pdq/              # the role (skeleton)
ansible/applications/windows_disk_manager/   # reused disk provisioner (3-disk init/partition/format)
ansible/playbooks/pdq.yml              # the AIO play (disk manager -> pdq)
ansible/inventory/vmware.yml           # dev VM inventory (SSH + PowerShell)
scripts/compose-and-run.sh             # compose + run (COMPOSE_PLAYBOOK=pdq.yml default)
scripts/{revert-vm,snapshot-step}.sh   # VM discipline (revert before EVERY run)
scripts/check-winshell-splitargs.py    # inline-PowerShell static gate
docs/                                  # Diátaxis + style guide, TECH-DEBT, VM-LIFECYCLE
terraform/                            # skeleton — NOT ACTIVE (AWS PoC layer deferred)
```

## Dev process

Work proceeds one command per cycle: each change is planned against vendor documentation,
independently reviewed before implementation, built in an isolated worktree, validated against
the static gate and the style guide, then merged with an audit-ledger row.

## Status

**Skeleton scaffolded 2026-07-27.** No PDQ operations implemented yet; `pdq/present_windows.yml`
is a validated no-op. Next: provision the PDQ dev VM + baseline snapshot, then start the queue at
piece P01. The AWS-PoC layer (workflows / terraform / IAM) is intentionally deferred — see
the upstream IAM, which must be finalized before it is cloned here.
