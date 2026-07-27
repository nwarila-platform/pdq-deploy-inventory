# VM lifecycle — PDQ dev VM (VMware Workstation)

Concise PDQ adaptation of the windows-wsus VM discipline. **The PDQ dev VM does not exist yet** —
provisioning it is the first infra task (see `_handoff/RESTART.md` §Environment). This doc records
the contract it must satisfy.

## 1. Baseline contract (what the role is handed)

A Windows Server 2025 guest in VMware Workstation with:
- OpenSSH server, `DefaultShell = PowerShell`, VMware Tools, a **static IP**, key-based SSH auth
  (the controller's persistent ssh-agent holds the key; the guest carries it in
  `administrators_authorized_keys`).
- **THREE attached BLANK/RAW data disks** — the role provisions them E:/F:/G:
  (`PDQDEPLOY` / `PDQINVENTORY` / `PDQSHARE`). No PDQ installed; fresh OS.
- A clean-baseline snapshot (running VM, memory included), e.g. `pre-ansible-clean-ssh-ready`.

The role configures this exact machine end-to-end, including disk init (`windows_disk_manager`).

## 2. Snapshot discipline (identical to windows-wsus)

- **Revert to the clean baseline before EVERY playbook execution** — `scripts/revert-vm.sh`
  (built into `compose-and-run.sh`; `SKIP_REVERT=1` only for composition testing). Never run
  against a dirty VM.
- At most TWO snapshots exist: the fresh-OS baseline anchor + one rolling `pre-<piece>` step
  snapshot (`scripts/snapshot-step.sh`, taken post-merge). `REVERT_TO=pre-<piece>` targets the
  rolling one; the baseline is re-proven E2E at END verify.

## 3. To provision (open task)

1. Build the Windows Server 2025 guest; attach 3 blank data disks; set a static IP.
2. Install OpenSSH (DefaultShell=PowerShell) + VMware Tools; seat the SSH key.
3. Snapshot the clean baseline (running, memory).
4. Update `ansible/inventory/vmware.yml` (`ansible_host`) and the VMX path + snapshot name in
   `scripts/revert-vm.sh` / `scripts/snapshot-step.sh` (they currently carry the windows-wsus
   dev-VM values — placeholders until the PDQ VM exists).
5. Capture the 3 disks' `Get-Disk` UniqueId (`eui.*`) into `ansible/playbooks/pdq.yml`
   (`deploy_disk_id` / `inventory_disk_id` / `share_disk_id`).

`vmrun` lives at `/mnt/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe`.
