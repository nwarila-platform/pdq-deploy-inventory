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
must supply the local service-account mapping.

The controller must have the `amazon.aws` collection and versions of `boto3` and `botocore`
supported by that collection. The currently installed `amazon.aws` 10.3.2 modules require
`boto3 >= 1.34.0` and `botocore >= 1.34.0`.

## Configuration

Role-specific overrides are supplied in the `pdq_inventory` dictionary and exposed to role tasks
as `config.*` after the loader merge. The installer settings have pinned defaults:

| Key | Required | Default / notes |
|---|---|---|
| `service_account.name` | yes | Name of the local PDQ Background Service User; validation rejects an empty name for `state: present` |
| `service_account.password` | yes for account creation | Secret used by `win_user`; it has no default and must be supplied through vault or a protected extra-vars file |
| `inventory_installer.version` | no | `20.1.8.0`; the required installed `DisplayVersion` |
| `inventory_installer.object_key` | no | `applications/pdq/Inventory_20.1.8.0.exe`; flat key in the account-local artifact bucket |
| `inventory_installer.sha256` | no | `48a486f3682cc01218993e72a8006163616166dd5f0fdcd1fab36724710fdbbf`; verified on the controller before transfer |
| `inventory_installer.region` | no | `us-east-1`; region used for the object download |
| `inventory_installer.staging_path` | no | `C:\Windows\Temp\Inventory_20.1.8.0.exe`; temporary path on the Windows target |
| `inventory_installer.product_id` | no | `{47D90CDF-2CE4-4B71-87DD-1223B1DA0AB2}`; uninstall-registration key and package identity |
| `temp_dir` | no | Generic loader control; the shipped playbook sets it to `false` because this Windows role does not use the loader's POSIX staging directory |

The role does not accept disk IDs, a licence key, Deploy repository settings, or Deploy disk
settings. Disk identity belongs to `windows_disk_manager.disks[].unique_id`.

## Artifact delivery and caller identity

Delivery is controller-mediated for each host that needs installation. The controller resolves
the AWS account of its ambient credentials, derives `<account-id>-ansible`, creates a unique
temporary directory, downloads the pinned object, and verifies its SHA-256 before copying or
executing anything on Windows. The target receives the verified bundle, never an AWS credential.

The role performs no identity transition. The caller's ambient credentials must themselves hold
the artifact grant. Credentials from another account derive that other account's bucket, and an
identity that can only assume the granting role is unsupported because this role does not perform
that assumption.

The controller AWS calls have this access contract:

- `amazon.aws.aws_caller_info` calls `sts:GetCallerIdentity`; the optional
  `iam:ListAccountAliases` result is not consumed.
- `amazon.aws.s3_object` needs `s3:GetObject` on
  `arn:aws:s3:::<account-id>-ansible/applications/pdq/*`. The shipped narrow grant also allows
  `s3:ListBucket` on `arn:aws:s3:::<account-id>-ansible` only when `s3:prefix` matches
  `applications/pdq/*`.

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
supported in check mode; the role refuses it without beginning delivery.

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

`present` ensures the Background Service User and the install state described above. `clean` is
intentionally a supported no-op. No absent-state teardown is implemented.
