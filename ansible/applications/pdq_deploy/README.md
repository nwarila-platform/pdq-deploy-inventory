# `pdq_deploy` role

Ensures the Windows prerequisites owned by PDQ Deploy: the shared PDQ Background Service User and
the Deploy repository/App Share. It does not yet install or configure PDQ Deploy.

## Composition and prerequisites

The role is overlaid into the pinned `nwarila-platform/ansible-framework` checkout at run time via
`scripts/compose-and-run.sh`; it is not run directly from this repository. The shipped
`ansible/playbooks/pdq.yml` runs `windows_disk_manager` before this role so the share disk is ready
before the repository is created.

`windows_disk_manager` plus `pdq_deploy` is a supported independent composition: it produces the
complete Deploy result currently implemented without relying on `pdq_inventory`. It ensures
both the Background Service User and the App Share.

The target must be Windows and must support the `ansible.windows.win_user`,
`ansible.windows.win_user_right`, `ansible.windows.win_file`, `ansible.windows.win_acl`, and
`ansible.windows.win_share` modules. The caller must supply the local service-account mapping, and
the configured share drive must already have been provisioned.

## Configuration

The role reads its merged configuration as `config.*`. These role defaults are defined in
`defaults/main.yml`:

| Key | Default | Notes |
|---|---|---|
| `data_disks.share.drive_letter` | `G` | Drive containing the Deploy repository |
| `data_disks.share.label` | `PDQSHARE` | Descriptive share-disk metadata; disk provisioning remains owned by `windows_disk_manager` |
| `data_disks.share.allocation_unit` | `4096` | Descriptive share-disk metadata; disk provisioning remains owned by `windows_disk_manager` |
| `repository.dir_name` | `AppRepo` | Repository directory below the configured share drive |
| `repository.share_name` | `AppRepo` | SMB share name |

The required role-specific override keys and loader control are:

| Key | Required | Notes |
|---|---|---|
| `service_account.name` | yes | Name of the local PDQ Background Service User; validation rejects an empty name for `state: present` |
| `service_account.password` | yes for account creation | Secret used by `win_user`; it has no default and must be supplied through vault or a protected extra-vars file |
| `temp_dir` | no | Generic loader control; the shipped playbook sets it to `false` because this Windows role needs no POSIX staging directory |

The role does not accept disk IDs or a licence key. Disk identity belongs to
`windows_disk_manager.disks[].unique_id`.

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

## State support

`present` ensures the prerequisites described above. `clean` is intentionally a supported no-op.
No absent-state teardown is implemented.
