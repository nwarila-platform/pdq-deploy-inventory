# `pdq_deploy` role

Ensures the shared PDQ Background Service User, creates the Deploy repository/App Share, and
installs the pinned PDQ Deploy artifact on Windows. The application operations in scope are
installation and writing the supplied licence value; the role does not select an operating mode or
port, configure the service credentials, start the service, or verify Enterprise mode.

## Composition and prerequisites

The role is overlaid into the pinned `nwarila-platform/ansible-framework` checkout at run time via
`scripts/compose-and-run.sh`; it is not run directly from this repository. The shipped
`ansible/playbooks/pdq.yml` runs `windows_disk_manager` before this role so the share disk is ready
before the repository is created.

`windows_disk_manager` plus `pdq_deploy` is a supported independent composition: with its required
inputs, it produces the complete Deploy result currently implemented without relying on
`pdq_inventory`. It ensures the Background Service User and App Share and installs Deploy.

The target must be Windows and support the `ansible.windows` modules used for account management,
registry and service observation, file transfer and removal, ACL and share management, and package
installation. The configured share drive must already have been provisioned. The caller must
supply the local service-account mapping and, for `state: present`,
`deploy_installer.artifact_bucket`.

The controller uses `ansible.builtin.tempfile`, `ansible.builtin.stat`, `ansible.builtin.assert`,
`ansible.builtin.file`, `ansible.builtin.fail`, and `amazon.aws.s3_object` for delivery and cleanup;
the shipped play also uses `amazon.aws.aws_caller_info`. Its Ansible environment must include the
`amazon.aws` collection and supported `boto3` and `botocore` versions. The Windows path uses
`ansible.windows.win_user`, `win_user_right`, `win_file`, `win_acl`, `win_share`, `win_reg_stat`,
`win_service_info`, `win_copy`, `win_stat`, and `win_package`.

## Configuration

Role-specific overrides are supplied in the `pdq_deploy` dictionary and exposed to role tasks as
`config.*` after the loader merge. The role settings are:

| Key | Required | Default / notes |
|---|---|---|
| `service_account.name` | yes | Name of the local PDQ Background Service User; validation rejects an empty name for `state: present` |
| `service_account.password` | yes for account creation | Secret used by `win_user`; it has no default and must be supplied through vault or a protected extra-vars file |
| `license` | yes for `state: present` | Licence text containing exactly one whole-line start marker, non-blank body content, and exactly one later whole-line end marker; written to the native 64-bit registry |
| `deploy_installer.version` | no | `20.1.8.0`; the required installed `DisplayVersion` |
| `deploy_installer.artifact_bucket` | yes for `state: present` | S3 bucket containing the installer; it has no safe default, and validation rejects undefined, non-string, empty, and whitespace-only values |
| `deploy_installer.object_key` | no | `PDQ/Deploy/20.1.8.0/PDQ_Deploy_x86-x64.exe`; installer object key in the caller-supplied artifact bucket |
| `deploy_installer.sha256` | no | `856dbe3dd4544d4b9ae1f382ee51f2a5f25f41714c462fa4afcff9743cc85eb9`; verified on the controller and again on the staged guest copy |
| `deploy_installer.region` | no | `us-east-1`; region used for the object download |
| `deploy_installer.staging_path` | no | `C:\Windows\Temp\PDQ_Deploy_x86-x64.exe`; fixed temporary path on the Windows target |
| `deploy_installer.product_id` | no | `{4E9FA177-A200-4DFC-9DC6-9D0290FCAAC2}`; uninstall-registration key and package identity |
| `data_disks.share.drive_letter` | no | `G`; drive containing the Deploy repository |
| `repository.dir_name` | no | `AppRepo`; repository directory below the configured share drive |
| `repository.share_name` | no | `AppRepo`; SMB share name |
| `temp_dir` | no | Generic loader control; the shipped playbook sets it to `false` because this Windows role does not use the loader's POSIX staging directory |

The role does not accept disk IDs. Disk identity belongs to `windows_disk_manager.disks[].unique_id`.

## Artifact delivery and controller caller identity

The shipped playbook resolves the AWS account of the controller's ambient credentials in a
`pre_tasks` call, composes `<account-id>-apprepo`, and maps that value to
`pdq_deploy.deploy_installer.artifact_bucket`. The current play has one batch, so its `run_once`
account lookup executes once and shares the registered result with all hosts in that batch. The
role itself neither resolves an AWS account nor composes a bucket name; another composition must
provide the required bucket input explicitly.

The account lookup is unconditional after fact gathering. It runs before any role in normal and
check mode, for `state: clean`, and when every target is already converged. A lookup failure occurs
before the role creates controller or guest delivery artifacts, so the role's delivery `rescue` and
`always` sections have nothing to report or remove on that path.

For each host admitted for installation, delivery is controller-mediated. The role creates a
unique controller temporary directory, downloads the pinned object from the supplied bucket, and
verifies its SHA-256 before transferring anything to Windows. It then copies the artifact to the
fixed guest staging path, calculates the staged file's SHA-256, and verifies that hash before
execution. Concurrent plays against the same target are unsupported because they would share that
fixed guest path.

No component in this path performs an identity transition. The caller's ambient credentials must
themselves permit the caller-identity lookup and artifact read. The Windows target receives the
verified artifact, never an AWS credential.

## App Share contract

The repository path is
`<config.data_disks.share.drive_letter>:\<config.repository.dir_name>`, which is `G:\AppRepo` with
the defaults. The role owns that directory, its explicit NTFS permissions, and the SMB share. It
ensures these explicit allow ACEs, inherited by child containers and objects:

- `BUILTIN\Users`: `ReadAndExecute`
- `BUILTIN\Administrators`: `FullControl`
- `NT AUTHORITY\SYSTEM`: `FullControl`

The SMB share uses `config.repository.share_name`, points to the repository path, disables offline
caching, and replaces the share permission set with `Administrators` as the full-access principal.
Inherited filesystem ACEs from the drive may also be present; the role's contract concerns the
three explicit ACEs it declares.

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

Two `GUARD` observations classify the starting installation state from the product's 32-bit
uninstall registration and the `PDQDeploy` service. Exactly two starting states are supported:

1. Clean absence: both the uninstall registration and service are absent. A normal run enters
   delivery and installs the pinned artifact.
2. Full convergence: the uninstall registration has `DisplayName` equal to `PDQ Deploy` and
   `DisplayVersion` equal to `deploy_installer.version`, and the service exists. Delivery is
   skipped and the final identity check still runs.

Every other starting identity fails closed at the final verification, including a missing or
incorrect display property, an unexpected version, or disagreement between the registration and
service. Upgrade, downgrade, and partial-install repair are outside the role's scope. Installation
from clean absence is not supported in check mode; the role skips delivery and reports that the
pinned artifact must be installed by a normal run.

The final verification checks only the uninstall identity and service existence. This role writes
the supplied licence value but does not select an operating mode or port, configure the Deploy
service credentials, start the service, or verify Enterprise mode. The service state is not
enforced; the pinned installer was observed to create `PDQDeploy` Stopped and Disabled.

## Cleanup behavior and limits

While a host remains active, the delivery unit attempts to remove its unique controller temporary
directory after success or failure. It attempts guest cleanup only if this run reached the staging
task and therefore defined the stage register; it never removes the fixed guest path on a run that
did not stage it. Both cleanup tasks ignore their immediate errors so the following task can report
the observed controller and guest cleanup outcomes together.

On a delivery failure, the delivery error is reported without projecting cleanup results, and
cleanup runs afterward. Cleanup failure is reported separately and remains status-neutral about
whether installation succeeded.

An unreachable host triggers neither `rescue` nor `always`. If the controller directory or a guest
copy already exists when the host becomes unreachable, that run can strand the artifact. There is
no later residue sweep: a converged run skips the delivery unit, and a controller directory from an
older run is not known to a newer one.

Compared with the `pdq_inventory` delivery pattern, Deploy intentionally has two asymmetries:

1. The staged guest copy is SHA-256 verified before execution, in addition to the controller-side
   verification.
2. Guest cleanup runs only when this run reached staging, as shown by its stage register.

## State support

`present` ensures the Background Service User, App Share, and install state described above.
Within the role, `clean` is intentionally a supported no-op and does not require
`deploy_installer.artifact_bucket`; no absent-state teardown is implemented. The shipped playbook
still performs its unconditional controller account lookup before the role on a `clean` run.
