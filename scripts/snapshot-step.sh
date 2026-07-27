#!/usr/bin/env bash
# =========================================================================================== #
# File: 'scripts/snapshot-step.sh'
# --- [ Description ] ----------------------------------------------------------------------- #
#
# Rolling per-step snapshot (Director, 2026-07-16): captures the VM's CURRENT state as the
# pre-change point for the NEXT piece, so its proof runs revert here (fast no-op of all
# merged pieces) instead of re-converging from the fresh-OS baseline every time.
#
#   Usage: scripts/snapshot-step.sh <next-piece-id>        e.g. snapshot-step.sh C06d
#
# Contract (docs/VM-LIFECYCLE.md §4):
#   - Take ONLY from a VERIFIED, MERGED post-piece state — never mid-proof, never from a
#     failed/dirty run. The baseline remains the only fresh-OS anchor and is NEVER touched.
#   - Exactly ONE rolling snapshot exists: any previous 'pre-*' step snapshot is deleted
#     first (VMware duplicates chain entries on same-name snapshots; count stays <= 2).
#   - Taken RUNNING with memory (revert resumes in seconds, no boot wait).
#
# =========================================================================================== #
set -euo pipefail

VMRUN="/mnt/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe"
VMX='D:\Documents\Virtual Machines\Windows Server 2025\Windows Server 2025.vmx'
BASELINE='pre-ansible-clean-ssh-ready'

[ $# -eq 1 ] || { echo "usage: $0 <next-piece-id>   (e.g. $0 C06d)" >&2; exit 1; }
NAME="pre-$1"
[ "${NAME}" != "${BASELINE}" ] || { echo "!! refusing to touch the baseline name" >&2; exit 1; }

# Delete any existing rolling snapshot (everything except the baseline).
# vmrun.exe emits CRLF — strip \r BEFORE comparing, or the baseline-skip test fails
# and the delete targets a '\r'-mangled name (worst case: the baseline itself).
"${VMRUN}" -T ws listSnapshots "${VMX}" | tr -d '\r' | tail -n +2 | while IFS= read -r snap; do
    [ -n "${snap}" ] || continue
    [ "${snap}" = "${BASELINE}" ] && continue
    echo ">> Deleting previous rolling snapshot '${snap}' ..."
    "${VMRUN}" -T ws deleteSnapshot "${VMX}" "${snap}"
done

echo ">> Taking rolling snapshot '${NAME}' (running VM, memory included) ..."
"${VMRUN}" -T ws snapshot "${VMX}" "${NAME}"

echo ">> Snapshots now on the VM:"
"${VMRUN}" -T ws listSnapshots "${VMX}"
