# pdq-deploy-inventory

A `nwarila-platform` application repository carrying separate **`pdq_inventory`** and
**`pdq_deploy`** Ansible roles for a PDQ Deploy and Inventory Central Server on Windows
Server. At execution time the play is composed into the version-pinned
[`ansible-framework`](https://github.com/nwarila-platform/ansible-framework) checkout.

The repository follows the same Windows SSH/PowerShell and three-disk conventions as the
explicit sibling reference [`windows-wsus`](../windows-wsus).

## What it deploys

| Drive | Label | Purpose |
|---|---|---|
| E: | `PDQDEPLOY` | PDQ Deploy database |
| F: | `PDQINVENTORY` | PDQ Inventory database |
| G: | `PDQSHARE` | PDQ Deploy repository and application share |

The intended topology places both applications on `pdq-dev` in Central Server mode under a
shared Background Service User, with client consoles connecting on TCP 7337.

## Quickstart

Prerequisites: the controller has `git`, `rsync`, and Ansible installed; its SSH identity
can read the framework repository; and the inventory target is reachable with authenticated
SSH access.

```bash
# Composes the pinned framework and runs pdq.yml
scripts/compose-and-run.sh -e env=dev -e @<absolute-operator-vars-file>
```

`<absolute-operator-vars-file>` must be an absolute path because the composer changes
directory before execution. It must live outside the repository with mode `600` and
supply `pdq_service_account_password`, `pdq_inventory_license`, and
`pdq_deploy_license`; no safe defaults exist by design, the file must never be committed,
and the default-deny allowlist cannot admit it.

The artifact delivery path requires live AWS credentials exported into the controller environment
before the run.

## Layout

| Path | Purpose |
|---|---|
| `ansible/applications/pdq_inventory/` | PDQ Inventory application role |
| `ansible/applications/pdq_deploy/` | PDQ Deploy application role and application share owner |
| `ansible/playbooks/pdq.yml` | Composed play: framework disk manager, Inventory, then Deploy |
| `ansible/inventory/vmware.yml` | `pdq-dev` inventory over SSH and PowerShell |
| `scripts/` | Composition, validation, and IAM helpers |
| `terraform/` | Inactive deploy-layer skeleton; see its README |
| `docs/ansible-style-guide.md` | Ansible design and authoring rules |
| `docs/TECH-DEBT.md` | Current engineering debt |

`windows_disk_manager` is supplied by the pinned framework; it is not an application
directory in this repository.

## Status

The automation for `pdq-dev` provisions E:, F:, and G:, publishes `G:\AppRepo`, creates the
shared local service account, and installs pinned PDQ Inventory and PDQ Deploy 20.1.8.0
bundles. Licence values are written, and the `pdq_deploy` role configures only `PDQDeploy` to use
that account, start automatically, and remain running. That service contract does not extend to
application mode, ports or firewall rules, database relocation, `pdq_inventory`, or
Enterprise-mode verification.

As of 2026-08-10, repository workflows are tracked and provide their configured gates; the
IAM foundation in `docs/reference/aws-iam/` is live and has been applied by
`scripts/bootstrap-iam.sh`. The Terraform skeleton is not active. The AWS deploy layer is
the next development direction, not a current capability.
