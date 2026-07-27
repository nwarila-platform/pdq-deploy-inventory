# windows_disk_manager

Validates the target's declared infrastructure platform before any Windows disk-management logic
runs. Framework-compatible role: ships the ansible-framework v3 generic loader (`tasks/main.yml`,
byte-identical to the repo's `wsus` loader — never edit) and a family-level `present_windows.yml`.

**Status: build in progress.** This piece is intentionally read-only: it has one Windows assert
and no disk facts, adapters, classification, or mutations. Later WDM pieces add those one command
per strict-cycle piece — see `_handoff/QUEUE.md` (repo root) for the build queue.

## Configuration

Defaults live under `windows_disk_manager_defaults` (`defaults/main.yml`) and merge with
`vars/windows[_<env>].yml` overlays plus the playbook's `windows_disk_manager:` override dict into
`windows_disk_manager_running` (exposed to task files as `config`).

### Required inputs

Declare these keys together in the `windows_disk_manager:` override dict in the playbook,
`group_vars`, `host_vars`, or extra-vars:

| `windows_disk_manager:` override key | Consumed as | Purpose |
|--------------------------------------|-------------|---------|
| `platform` | `config.platform` | Required declared infrastructure platform. Valid values are `vmware` and `aws`; `proxmox` is deliberately not accepted until measured. The Windows present guard compares the observed `ansible_facts.system_vendor` exactly against the expected vendor string (`VMware, Inc.` or `Amazon EC2`) and does not lower-case the observed value. |
| `temp_dir` | loader raw var | Must be `false` on Windows until TD-001 is fixed upstream; it disables the loader's POSIX temp-dir path for this role. |

The `platform` and `temp_dir` keys must co-locate in one `windows_disk_manager:` declaration. The
loader reads `temp_dir` from the raw role var, and Ansible does not merge role override dicts
across precedence levels; a higher-precedence `windows_disk_manager:` value replaces the whole
mapping. A proof override such as `-e '{"windows_disk_manager":{"platform":"aws"}}'` is therefore
wrong on Windows because it drops `temp_dir: false`; restate both keys, for example:
`-e '{"windows_disk_manager":{"platform":"aws","temp_dir":false}}'`.

### Merged configuration

| `windows_disk_manager_defaults` key | Default | Purpose |
|-------------------------------------|---------|---------|
| `platform` | `''` | No usable default. Validation requires a non-empty declared platform, normalizes it to a lower-case key, and accepts only `vmware` or `aws`. |

## Requirements

- Windows Server target over SSH (`ansible_shell_type: powershell`, OpenSSH `DefaultShell` =
  PowerShell), elevated admin account, `become: false`.
- `ENV` play-var (loader-validated) and the TD-001 `temp_dir: false` role override — see
  `docs/TECH-DEBT.md`.
