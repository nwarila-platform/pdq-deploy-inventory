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

Both applications run on `pdq-dev` in Central Server mode under a shared Background
Service User. Client consoles connect on TCP 7337.

## Quickstart (lab)

```bash
# Reverts by default, composes the pinned framework, and runs pdq.yml
scripts/compose-and-run.sh -e env=dev -e @<operator-vars-file>
```

`<operator-vars-file>` must live outside the repository with mode `600` and supply
`pdq_service_account_password`, `pdq_inventory_license`, and `pdq_deploy_license`;
no safe defaults exist by design, the file must never be committed, and the
default-deny allowlist cannot admit it.

Use `scripts/revert-vm.sh` separately for snapshot recovery or connectivity diagnosis.

## Layout

| Path | Purpose |
|---|---|
| `ansible/applications/pdq_inventory/` | PDQ Inventory application role |
| `ansible/applications/pdq_deploy/` | PDQ Deploy application role and application share owner |
| `ansible/playbooks/pdq.yml` | Composed play: framework disk manager, Inventory, then Deploy |
| `ansible/inventory/vmware.yml` | `pdq-dev` inventory over SSH and PowerShell |
| `scripts/` | Composition, validation, snapshot, and IAM helpers |
| `terraform/` | Inactive deploy-layer skeleton; see its README |
| `docs/ansible-style-guide.md` | Ansible design and authoring rules |
| `docs/TECH-DEBT.md` | Current engineering debt |

`windows_disk_manager` is supplied by the pinned framework; it is not an application
directory in this repository.

## Status

The `pdq-dev` baseline was provisioned 2026-07-27. The automation provisions E:, F:, and
G:, publishes `G:\AppRepo`, creates the shared local service account, and installs pinned
PDQ Inventory and PDQ Deploy 20.1.8.0 bundles. Licence values are written, but application
mode, service startup, and Enterprise-mode verification are not implemented.

As of 2026-08-10, repository workflows are tracked and provide their configured gates; the
IAM foundation in `docs/reference/aws-iam/` is live and has been applied by
`scripts/bootstrap-iam.sh`. The Terraform skeleton is not active. The AWS deploy layer is
the next development direction, not a current capability.
