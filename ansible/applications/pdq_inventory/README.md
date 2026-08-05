# `pdq_inventory` role

Ensures the shared PDQ Background Service User and installs the pinned PDQ Inventory bundle on
Windows. It does not create or publish the PDQ Deploy repository/App Share. Installation is the
only application operation in scope: the role does not license Inventory, select its operating
mode, configure its service credentials, or start it.

## Composition and prerequisites

The role is overlaid into the pinned `nwarila-platform/ansible-framework` checkout at run time via
`scripts/compose-and-run.sh`; it is not run directly from this repository. The shipped
`ansible/playbooks/pdq.yml` runs `windows_disk_manager` before this role so the Inventory data disk
is provisioned independently of the application role.

`windows_disk_manager` plus `pdq_inventory` is a supported independent composition: it produces
the complete Inventory result currently implemented without relying on `pdq_deploy`. In
particular, it ensures the Background Service User and installs Inventory, but creates no Deploy
repository directory or SMB share.

The target must be Windows and support the `ansible.windows` modules used for account management,
registry and service observation, file transfer and removal, and package installation. The caller
must supply the local service-account mapping and, for `state: present`,
`inventory_installer.artifact_bucket`.

The shipped inventory pins the controller host to `ansible_playbook_python`, so delegated modules
run under the playbook Python. The Ansible environment must include the `amazon.aws` collection,
and that Python environment must contain supported versions of `boto3` and `botocore`. The role
uses `amazon.aws.s3_object`; the shipped playbook also uses `amazon.aws.aws_caller_info`. The
currently installed `amazon.aws` 10.3.2 modules require `boto3 >= 1.34.0` and
`botocore >= 1.34.0`.

## Configuration

Role-specific overrides are supplied in the `pdq_inventory` dictionary and exposed to role tasks
as `config.*` after the loader merge. The installer settings have pinned defaults:

| Key | Required | Default / notes |
|---|---|---|
| `service_account.name` | yes | Name of the local PDQ Background Service User; validation rejects an empty name for `state: present` |
| `service_account.password` | yes for account creation | Secret used by `win_user`; it has no default and must be supplied through vault or a protected extra-vars file |
| `inventory_installer.version` | no | `20.1.8.0`; the required installed `DisplayVersion` |
| `inventory_installer.artifact_bucket` | yes for `state: present` | S3 bucket containing the installer; it has no default, and validation rejects undefined, non-string, empty and whitespace-only values |
| `inventory_installer.object_key` | no | `applications/pdq/Inventory_20.1.8.0.exe`; installer object key in the caller-supplied artifact bucket |
| `inventory_installer.sha256` | no | `48a486f3682cc01218993e72a8006163616166dd5f0fdcd1fab36724710fdbbf`; verified on the controller before transfer |
| `inventory_installer.region` | no | `us-east-1`; region used for the object download |
| `inventory_installer.staging_path` | no | `C:\Windows\Temp\Inventory_20.1.8.0.exe`; temporary path on the Windows target |
| `inventory_installer.product_id` | no | `{47D90CDF-2CE4-4B71-87DD-1223B1DA0AB2}`; uninstall-registration key and package identity |
| `temp_dir` | no | Generic loader control; the shipped playbook sets it to `false` because this Windows role does not use the loader's POSIX staging directory |

The role does not accept disk IDs, a licence key, Deploy repository settings, or Deploy disk
settings. Disk identity belongs to `windows_disk_manager.disks[].unique_id`.

## Artifact delivery and caller identity

The shipped playbook resolves the AWS account of the controller's ambient credentials in a
`pre_tasks` call, composes `<account-id>-ansible`, and maps that value to
`pdq_inventory.inventory_installer.artifact_bucket`. The current play has one batch, so its
`run_once` account lookup executes once and shares the registered result with all hosts in that
batch. The role itself neither resolves an AWS account nor composes a bucket name; another
composition must provide the required bucket input explicitly.

The account lookup is unconditional after fact gathering. It runs before any role in normal and
check mode, for `state: clean`, and when every target is already converged. A lookup failure is
reported directly from the pre-task: it does not enter the role's delivery `rescue` or `always`
sections. The lookup also precedes creation of the controller and guest temporary artifacts, so
there is no delivery artifact for those sections to clean up on that failure path.

For each host that needs installation, delivery remains controller-mediated. The role creates a
unique controller temporary directory, downloads the pinned object from the supplied bucket, and
verifies its SHA-256 before copying or executing anything on Windows. The target receives the
verified bundle, never an AWS credential.

No component in this path performs an identity transition. The caller's ambient credentials must
themselves hold the artifact grant. In the shipped playbook, credentials from another account
derive that other account's bucket. An identity that can only assume the granting role is
unsupported because neither the playbook nor the role performs that assumption.

The controller AWS calls have this access contract:

- The shipped playbook's `amazon.aws.aws_caller_info` pre-task calls `sts:GetCallerIdentity`; the
  optional `iam:ListAccountAliases` result is not consumed.
- `amazon.aws.s3_object` needs `s3:GetObject` on
  `arn:aws:s3:::<artifact-bucket>/applications/pdq/*`. For the shipped playbook's composed bucket,
  the narrow grant also allows `s3:ListBucket` on `arn:aws:s3:::<account-id>-ansible` only when
  `s3:prefix` matches `applications/pdq/*`.

The download sets `ignore_nonexistent_bucket: true` because the module's initial bucket-root
probe is denied by that prefix-bounded grant. Suppressing the convenience probe preserves the
narrow object and prefix permissions; the grant is not widened merely to satisfy a preliminary
lookup.

## Background Service User and one-identity contract

For `state: present`, the role ensures a local account with password updates limited to account
creation, adds it to `Administrators`, prevents password expiry and user-initiated password
changes, and grants `SeServiceLogonRight`. The account task is protected with `no_log: true`.
Changing the configured password does not rotate an existing account because
`update_password: on_create` is used.

PDQ Deploy and PDQ Inventory remain co-located in the shipped topology, in the same operating
mode, under one Background Service User. The playbook defines `pdq_service_account` once and maps
that whole mapping into both `pdq_inventory.service_account` and
`pdq_deploy.service_account`. Each role nevertheless validates and consumes its own namespace so
it can run independently.

This one-identity invariant is structural in the shipped playbook, not an Ansible-enforced
impossibility. A caller that replaces either complete role dictionary through extra-vars must map
the same whole service-account value into both namespaces when composing both roles.

## Installation state contract

Exactly two starting states are supported:

1. Clean absence: both the product's uninstall registration and the `PDQInventory` service are
   absent. A normal run enters delivery and installs the pinned bundle.
2. Full convergence: the uninstall registration has `DisplayName` equal to `PDQ Inventory` and
   `DisplayVersion` equal to `inventory_installer.version`, and the `PDQInventory` service exists.
   Delivery is skipped and the final identity check still runs.

Every other starting state fails closed, including a missing or incorrect display property, an
unexpected version, or disagreement between the registration and service. Upgrade, downgrade and
partial-install repair are outside the role's scope. Installation from clean absence is not
supported in check mode; after the shipped playbook's account lookup, the role refuses it without
beginning delivery.

This role installs only. It does not apply a licence, select Local/Client/Server mode, configure
the service account in Inventory, or start the service. The service is left exactly as the
installer delivers it, measured for this bundle as Stopped and Disabled.

## Cleanup limits

While a host remains active, the delivery unit attempts to remove both its controller temporary
directory and its guest staging file after success or failure. On a delivery failure, the delivery
error is reported first without cleanup projections, and cleanup runs afterward. If cleanup also
fails, the run produces two failure records: the delivery error followed by the cleanup-specific
report. A cleanup failure following a successful installation also fails the run with that report;
it is not mislabeled as an installation failure.

The cleanup report is status-neutral about the installation because it can follow either a
successful or a failed delivery. It claims neither outcome and reports only the cleanup results:

```yaml
PDQ Inventory artifact cleanup failed. Cleanup results: controller cleanup failed={{
__inventory_controller_cleanup__.failed | default(false) }}; guest cleanup failed={{
__inventory_guest_cleanup__.failed | default(false) }}.
```

An unreachable host triggers neither `rescue` nor `always`. The controller cleanup is delegated
from that now-inactive host, so losing the target strands both the guest staging file and the
controller temporary directory. A later run creates a fresh controller directory and does not
remove the older one; controller residue can therefore accumulate until separately removed.

## State support

`present` ensures the Background Service User and the install state described above. Within the
role, `clean` is intentionally a supported no-op and does not require `artifact_bucket`; no
absent-state teardown is implemented. The shipped playbook still performs its unconditional
controller account lookup before the role on a `clean` run.
