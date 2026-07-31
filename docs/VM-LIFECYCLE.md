# VM lifecycle — PDQ dev VM (VMware Workstation)

Concise PDQ adaptation of the windows-wsus VM discipline. The `pdq-dev` VM was provisioned
2026-07-27 at `D:\Documents\Virtual Machines\pdq-dev\pdq-dev.vmx`. It uses static address
`192.168.0.182`, has its own generated MAC, and no longer collides with the windows-wsus dev VM.

## 1. Baseline contract (what the role is handed)

A Windows Server 2025 guest in VMware Workstation with:
- OpenSSH server, `DefaultShell = PowerShell`, VMware Tools, a **static IP**, key-based SSH auth
  (the controller's persistent ssh-agent holds the key; the guest carries it in
  `administrators_authorized_keys`).
- **THREE attached BLANK/RAW data disks** — the role provisions them E:/F:/G:
  (`PDQDEPLOY` / `PDQINVENTORY` / `PDQSHARE`). No PDQ installed; fresh OS.
- A clean-baseline snapshot (running VM, memory included), e.g. `pre-ansible-clean-ssh-ready`.

The role provisions the data disks, repository share, and local service account on this machine.
It installs the pinned PDQ Inventory bundle, but Inventory is not yet licensed, mode-configured,
or started, and PDQ Deploy is not yet installed or configured.

## 2. Snapshot discipline (identical to windows-wsus)

- **Revert to the clean baseline before EVERY playbook execution** — `scripts/revert-vm.sh`
  (built into `compose-and-run.sh`). `SKIP_REVERT=1` is ratified only for composition testing and
  an idempotency proof immediately after a revert-first converge. It is not a general escape hatch
  for live runs.
- At most TWO snapshots exist: the fresh-OS baseline anchor + one rolling `pre-<piece>` step
  snapshot (`scripts/snapshot-step.sh`, taken post-merge). `REVERT_TO=pre-<piece>` targets the
  rolling one; the baseline is re-proven E2E at END verify.

## 3. Provisioning record

1. Build the Windows Server 2025 guest; attach 3 blank data disks; set a static IP.
2. Install OpenSSH (DefaultShell=PowerShell) + VMware Tools; seat the SSH key.
3. Snapshot the clean baseline (running, memory).
4. Record `ansible_host` as `192.168.0.182` in `ansible/inventory/vmware.yml`; record the PDQ VMX
   path and `pre-ansible-clean-ssh-ready` baseline in `scripts/revert-vm.sh` and
   `scripts/snapshot-step.sh`.
5. Capture the 3 disks' `Get-Disk` UniqueId (`eui.*`) in each corresponding
   `windows_disk_manager.disks[].unique_id` entry in `ansible/playbooks/pdq.yml`.

`vmrun` lives at `/mnt/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe`.
