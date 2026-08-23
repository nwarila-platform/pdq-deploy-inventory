# pdq-deploy-inventory

A `nwarila-platform` application repository carrying separate **`pdq_inventory`** and
**`pdq_deploy`** Ansible roles that compose into a single all-in-one **PDQ Deploy and Inventory
Central Server** on Windows Server. At execution time the roles overlay onto a version-pinned
[`ansible-framework`](https://github.com/nwarila-platform/ansible-framework) checkout, whose
`windows_disk_manager` provisions the disks; the host is deployed on ephemeral AWS through GitHub
Actions and torn down on the same run.

## What it deploys

| Drive | Label | Purpose |
|---|---|---|
| D: | `PDQINVENTORY` | PDQ Inventory database |
| E: | `PDQDEPLOY` | PDQ Deploy database |
| F: | `PDQREPO` | PDQ Deploy package repository and application share |

Both products run co-located in **Central Server** mode under one shared Background Service User
(`svc-pdq`). Client consoles connect to PDQ Inventory on TCP **7337** and to PDQ Deploy on TCP
**6336**. Every artifact — each product's installer, its licence, and the service-account password —
is fetched from the account's S3 buckets and verified against a pinned SHA-256 before use; no
secret is ever committed.

## How it runs

The `aws-deploy` workflow owns the lifecycle: terraform provisions the Windows host, the composed
`pdq-aws.yml` play installs and configures both products, an **idempotency gate** proves the second
converge is a no-op, and terraform destroys the host. A push to `main` proves it immediately;
`workflow_dispatch` adds `hold_minutes` (keep the converged host up for interactive work) and
`os_swap` (below).

Locally, `scripts/compose-and-run.sh` builds the same composed tree and runs the play against a
chosen inventory (`COMPOSE_INVENTORY=ansible/inventory/aws_ec2.yml`), given live AWS credentials.

## OS-drive replacement

The data volumes (D:, E:, F:) are standalone and independent of the OS disk. Bumping the framework's
`refresh_serial` — or dispatching `aws-deploy` with `os_swap=true` — **replaces the OS instance in
place while the same data volumes detach and re-attach**, and PDQ resumes on its existing databases
and repository. The disk role adopts an already-labelled volume without reformatting and re-asserts
its drive letter; the server's only machine-tied state is credentials, which the roles re-establish
from S3 each converge. Proven idempotent across repeated OS replacements with the data preserved.

## Layout

| Path | Purpose |
|---|---|
| `ansible/applications/pdq_inventory/` | PDQ Inventory application role |
| `ansible/applications/pdq_deploy/` | PDQ Deploy application role and repository/share owner |
| `ansible/playbooks/pdq-aws.yml` | Composed play: inventory contract, host readiness, framework disk manager, then both products |
| `ansible/inventory/aws_ec2.yml` | Dynamic AWS inventory (filters this run's instance by tag) |
| `terraform/aws.tfvars` | Data-only input to the pinned aws-terraform-framework (no `.tf` files here) |
| `scripts/` | Composition, script materialization, and IAM helpers |
| `docs/ansible-style-guide.md` | Ansible design and authoring rules |
| `docs/TECH-DEBT.md` | Current engineering debt |

`windows_disk_manager` and all terraform resources are supplied by the pinned frameworks; this
repository declares neither.

## Status

Both application roles are built, independently reviewed, and proven on ephemeral AWS: a full
converge (install, licence, Central Server mode, ports, firewall, database on its dedicated drive,
preferences, console users, registration) followed by a green idempotency gate. The AWS pipeline is
live end to end — provision, converge, prove, destroy — and OS-drive replacement with reattached
data volumes is a proven capability. Pinned product version: 20.1.8.0.
