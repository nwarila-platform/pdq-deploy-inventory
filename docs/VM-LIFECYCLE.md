# VM lifecycle — dev target ownership and procedures

The `pdq-dev` VM is a disposable execution target with a durable baseline. The operator
contract is to begin deployment evidence from a known snapshot; the explicit
`SKIP_REVERT=1` modes below are the only exceptions.

## 1. Baseline snapshot contract

- Name: **`pre-ansible-clean-ssh-ready`**.
- Contents: Windows Server 2025, VMware Tools, OpenSSH key authentication for
  `administrator`, PowerShell as the default shell, static address `192.168.0.182`, and
  three attached blank/RAW data disks. No application state is baked into the baseline.
- The data disks are initialized by the pinned framework `windows_disk_manager` role from
  `ansible/playbooks/pdq.yml`, then exposed as E: `PDQDEPLOY`, F: `PDQINVENTORY`, and
  G: `PDQSHARE`. Their `eui.*` identifiers are recorded in that playbook.
- No OS-disk identifier is recorded by this repository.
- A baseline is never taken from a guest changed by a deployment run since its last revert.

## 2. Supported execution modes

- **Normal:** `scripts/compose-and-run.sh -e env=dev -e @<absolute-operator-vars-file>` reverts
  first, composes the pinned framework with this repository, and runs `pdq.yml`.
- **Rolling snapshot:**
  `REVERT_TO=pre-<change> scripts/compose-and-run.sh -e env=dev -e @<absolute-operator-vars-file>`
  starts from a previously verified snapshot named for the next planned change.
- In both commands, `<absolute-operator-vars-file>` must be an absolute path to a file outside
  the repository with mode `600` that supplies `pdq_service_account_password`,
  `pdq_inventory_license`, and `pdq_deploy_license`; no safe defaults exist, the file must
  never be committed, and the default-deny allowlist cannot admit it.
- **No-revert exception:** `SKIP_REVERT=1` is limited to an immediate idempotency rerun,
  a declared precondition-state negative test, or composition testing. It supplies no
  clean-baseline evidence and must not be snapshotted.
- `scripts/revert-vm.sh` also performs a guest `w32tm /resync` after SSH becomes reachable;
  the helper is therefore not purely a snapshot operation.

## 3. Provisioning record

1. Build the Windows Server 2025 guest; attach three blank data disks; set a static IP.
2. Install OpenSSH with PowerShell as `DefaultShell`, install VMware Tools, and authorize
   the SSH key.
3. Snapshot the clean running guest as `pre-ansible-clean-ssh-ready`.
4. Record `192.168.0.182` in `ansible/inventory/vmware.yml` and the `pdq-dev` VM path and
   baseline name in the VM helper scripts.
5. Record each data disk's `Get-Disk` `UniqueId` in the corresponding
   `windows_disk_manager.disks[].unique_id` entry in `ansible/playbooks/pdq.yml`.

`vmrun` is invoked from `/mnt/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe`.

## 4. Snapshot hygiene

- Keep the baseline plus at most one rolling `pre-<change>` snapshot.
- `scripts/snapshot-step.sh` deletes the previous rolling snapshot before creating its
  replacement; duplicate snapshot names are not permitted.
- Do not keep experimental snapshots. Re-baseline only for an operator-approved baseline
  change, then prove revert and SSH readiness before the next deployment run.
- Formatting, labeling, and assigning letters to data disks belong to the composed play,
  never the baseline.

## 5. Network and machine identity

- `192.168.0.182` selects a connection destination; neither the address nor hostname proves
  which machine answered.
- This repository does **not mechanically verify VM identity**. `scripts/revert-vm.sh`
  verifies only SSH reachability and then runs the mutating time-resynchronization command.
  Operators must establish that `pdq-dev` owns the address before relying on a run.
- Data-volume recognition is a separate safety convention, not a VM identity gate. The
  disk manager selects declared `eui.*` identifiers and recognizes managed NTFS volumes by
  their labels: `PDQDEPLOY`, `PDQINVENTORY`, and `PDQSHARE`.

## 6. Failure playbook

| Symptom | Likely cause | Action |
|---|---|---|
| Snapshot revert errors | name drift or duplicate chain | List snapshots and restore the baseline/rolling-snapshot invariant. |
| SSH never returns | VM powered off, address conflict, or guest firewall | Check running VMs, start `pdq-dev` if needed, and use `getGuestIPAddress` or the console. |
| Machine at the address is uncertain | no mechanical identity check exists | Stop; establish which VM owns `192.168.0.182` before continuing. |
| Key authentication suddenly fails | controller agent empty after reboot | Run `ssh-add -l`, then follow `docs/KEY-RELOAD.md`. |
| Guest clock is skewed | memory-snapshot resume | The revert helper runs `w32tm /resync`; inspect its result. |
| First task stalls | stale SSH multiplexing socket | The composer clears its local socket directory; clear the controller socket for manual runs. |

## 7. Ownership boundaries

- The composed play and its ordered roles own guest application and data-volume state.
- The revert helper additionally owns its explicit clock resynchronization.
- Re-baselining owns approved baseline changes. Other guest hand-edits invalidate the
  clean-baseline guarantee.
- VM hardware and configuration changes require an approved re-baseline.
