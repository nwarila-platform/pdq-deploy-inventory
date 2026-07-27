#!/usr/bin/env python3
# =========================================================================================== #
# File: 'scripts/adopt-lab-vmx.py'
# --- [ Description ] ----------------------------------------------------------------------- #
#
# Item-5 (OS-disk replacement / adopt-existing-volumes) LAB HARNESS — NOT part of the role.
#
# Prepares the throwaway lab VM that simulates an AWS AMI swap: a FRESH-OS full clone of the dev
# VM whose three data disks are replaced by clones of the POPULATED WSUSDB/WSUSDATA/WSUSIIS
# volumes. Booting it is the moment of the "swap": a brand-new OS meeting pre-existing WSUS data.
#
# Two edits, both idempotent (safe to re-run; a VMware operation may rewrite the VMX):
#   1. NIC identity — force the ORIGINAL MAC. A full clone otherwise mints a new MAC, Windows can
#      then treat it as a new adapter and drop the baked-in static IP (192.168.0.181), which would
#      cost us SSH with no console fallback (we hold no guest password). checkMACAddress=FALSE is
#      required because the original MAC is in VMware's 00:0C:29 "generated" range, which is
#      normally rejected as a manually-assigned address.
#   2. Data disks — repoint nvme0:1/2/3 at the *-adopt.vmdk clones as independent-persistent, so
#      they are excluded from the lab VM's snapshot machinery (the EBS semantic being modelled).
#
# The PRIMARY VM and its two snapshots are never touched by this script.
#
#   Usage: python3 scripts/adopt-lab-vmx.py [--vmx <path>] [--mac 00:0C:29:98:E2:69]
# =========================================================================================== #
import argparse
import os
import re
import sys

DEFAULT_VMX = '/mnt/d/Documents/Virtual Machines/wsus-adopt-lab/wsus-adopt-lab.vmx'
DEFAULT_MAC = '00:0C:29:98:E2:69'
DISKS = {
    'nvme0:1': 'WSUSDB-adopt.vmdk',
    'nvme0:2': 'WSUSDATA-adopt.vmdk',
    'nvme0:3': 'WSUSIIS-adopt.vmdk',
}
# keys we own and therefore rewrite wholesale
DROP_PREFIXES = (
    'ethernet0.addresstype', 'ethernet0.address', 'ethernet0.generatedaddress',
    'ethernet0.generatedaddressoffset', 'ethernet0.checkmacaddress',
)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument('--vmx', default=DEFAULT_VMX)
    ap.add_argument('--mac', default=DEFAULT_MAC)
    args = ap.parse_args(argv)

    if not os.path.isfile(args.vmx):
        sys.stderr.write('lab VMX not found: %s\n' % args.vmx)
        return 2

    with open(args.vmx, encoding='utf-8', errors='ignore') as fh:
        lines = fh.readlines()

    out = []
    for line in lines:
        key = line.split('=')[0].strip().lower()
        node = line.split('.')[0].strip()
        # drop NIC identity keys (re-added below)
        if key.startswith(DROP_PREFIXES):
            continue
        # rewrite the data-disk backing; drop any stale mode/redo for those nodes
        if node in DISKS and re.search(r'\.(fileName|mode|redo)\s*=', line):
            continue
        out.append(line)

    if out and not out[-1].endswith('\n'):
        out[-1] += '\n'

    # 1. NIC identity — keep the original MAC so the guest's static IP (and our SSH) survives
    out.append('ethernet0.addressType = "static"\n')
    out.append('ethernet0.address = "%s"\n' % args.mac)
    out.append('ethernet0.checkMACAddress = "FALSE"\n')

    # 2. data disks -> the populated adopt clones, independent-persistent (EBS semantic)
    for node, fname in DISKS.items():
        out.append('%s.fileName = "%s"\n' % (node, fname))
        out.append('%s.mode = "independent-persistent"\n' % node)

    with open(args.vmx, 'w', encoding='utf-8') as fh:
        fh.writelines(out)

    print('lab VMX prepared: %s' % args.vmx)
    print('  MAC forced   : %s (checkMACAddress=FALSE)' % args.mac)
    for node, fname in DISKS.items():
        print('  %s -> %s (independent-persistent)' % (node, fname))
    return 0


if __name__ == '__main__':
    sys.exit(main())
