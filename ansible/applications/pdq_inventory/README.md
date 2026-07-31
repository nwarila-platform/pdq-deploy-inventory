# `pdq_inventory` role

Ensures the Windows prerequisites owned by PDQ Inventory. In the current implementation, that is
the shared PDQ Background Service User. This role does not create or publish the PDQ Deploy
repository/App Share, and it does not yet install or configure PDQ Inventory.

## Composition and prerequisites

The role is overlaid into the pinned `nwarila-platform/ansible-framework` checkout at run time via
`scripts/compose-and-run.sh`; it is not run directly from this repository. The shipped
`ansible/playbooks/pdq.yml` runs `windows_disk_manager` before this role so the Inventory data disk
is provisioned independently of the application role.

`windows_disk_manager` plus `pdq_inventory` is a supported independent composition: it produces
the complete Inventory result currently implemented without relying on `pdq_deploy`. In
particular, it ensures the Background Service User but creates no repository directory or SMB
share.

The target must be Windows and must support the `ansible.windows.win_user` and
`ansible.windows.win_user_right` modules. The caller must supply the local service-account mapping.

## Configuration

`pdq_inventory_defaults` is empty. The required role-specific input is supplied in the
`pdq_inventory` override dictionary and is exposed to role tasks as `config.*` after the loader
merge.

| Key | Required | Notes |
|---|---|---|
| `service_account.name` | yes | Name of the local PDQ Background Service User; validation rejects an empty name for `state: present` |
| `service_account.password` | yes for account creation | Secret used by `win_user`; it has no default and must be supplied through vault or a protected extra-vars file |
| `temp_dir` | no | Generic loader control; the shipped playbook sets it to `false` because this Windows role needs no POSIX staging directory |

The role does not accept disk IDs, a licence key, Deploy repository settings, or Deploy disk
settings. Disk identity belongs to `windows_disk_manager.disks[].unique_id`.

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
