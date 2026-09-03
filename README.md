# pdq-deploy-inventory

This repository automates the full Windows host and **PDQ Deploy and Inventory Central Server**
configuration lifecycle in an ephemeral AWS environment. Terraform separates the replaceable
Windows OS disk from three encrypted data volumes that persist across OS replacement. Ansible
installs and licences both products, runs their services under one account, places their databases,
publishes the Deploy repository, and converges preferences, variables, registration, and console
users. GitHub Actions provisions the host, can replace it while reattaching the same data volumes,
reconverges the applications, proves the bounded idempotency result, and destroys the environment.

At execution time the two application roles overlay onto a version-pinned
[`ansible-framework`](https://github.com/nwarila-platform/ansible-framework) checkout, whose
`windows_disk_manager` provisions the disks.

## Scope

The AWS deployment builds domain-joined hosts. `ansible/playbooks/pdq-aws.yml` joins each guest
to the directory, and `ansible/playbooks/ad-config.yml` prepares what the server depends on
there: the service account, the OU a PDQ server is filed in, and the account's Windows LAPS read
permissions on the OUs PDQ manages.

The products themselves still run their background service as a LOCAL account, which is
deliberate. What is not yet done is the credential PDQ authenticates to TARGETS with: it is that
local account today, so scans and deployments cannot reach another machine. Group-based console
authorisation and RBAC hardening remain future work.

**Before adopting this in another environment, read
[docs/how-to/adopt-this-repository.md](docs/how-to/adopt-this-repository.md).** Nothing in the
prerequisite list is created by the pipeline.

## What it deploys

| Drive | Label | Purpose |
|---|---|---|
| D: | `PDQINVENTORY` | PDQ Inventory database |
| E: | `PDQDEPLOY` | PDQ Deploy database |
| F: | `PDQREPO` | PDQ Deploy package repository and application share |

Both products run co-located in **Central Server** mode under one shared Background Service User
(`svc-pdq`). Client consoles connect to PDQ Inventory on TCP **7337** and to PDQ Deploy on TCP
**6336**. The controller fetches each product's installer, licence, and the service-account password
from S3 without giving the guest cloud credentials. Installer and licence content is verified
against pinned SHA-256 values; the password is held in memory, rejected if empty, and represented in
the repository only by its object location.

## How it runs

The `aws-deploy` workflow owns the lifecycle: terraform provisions the Windows host, the composed
`pdq-aws.yml` play installs and configures both products, an **idempotency gate** proves the second
converge reports only the two expected service-credential reassertions, and terraform destroys the
host. A push to `main` proves it immediately;
`workflow_dispatch` adds `hold_minutes` (keep the converged host up for interactive work) and
`os_swap` (below).

Locally, `scripts/compose-and-run.sh` builds the same composed tree and runs the play against a
chosen inventory (`COMPOSE_INVENTORY=ansible/inventory/aws_ec2.yml`), given live AWS credentials.

## OS-drive replacement

The data volumes (D:, E:, F:) are standalone and independent of the OS disk. Bumping the framework's
`refresh_serial` — or dispatching `aws-deploy` with `os_swap=true` — **replaces the OS instance in
place while the same data volumes detach and re-attach**, and PDQ resumes on its existing databases
and repository. The disk role adopts an already-labelled volume without reformatting and re-asserts
its drive letter; the roles reinstall the applications and reapply their machine-local
configuration and credentials. The opt-in workflow then runs the same bounded idempotency gate on
the rebuilt host with the data preserved.

## Layout

| Path | Purpose |
|---|---|
| `ansible/applications/pdq_inventory/` | PDQ Inventory application role |
| `ansible/applications/pdq_deploy/` | PDQ Deploy application role and repository/share owner |
| `ansible/playbooks/pdq-aws.yml` | Composed play: inventory contract, host readiness, framework disk manager, then both products |
| `ansible/inventory/aws_ec2.yml` | Dynamic AWS inventory (filters this run's instance by tag) |
| `terraform/aws.tfvars` | Data-only input to the pinned aws-terraform-framework (no `.tf` files here) |
| `scripts/` | Composition, script materialization, and the products' PowerShell utilities |
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
