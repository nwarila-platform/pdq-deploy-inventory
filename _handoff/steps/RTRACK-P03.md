# RTRACK-P03 — App Share on G: (dir + NTFS ACL + SMB share)

**Merged** `0c4c9a0 [audited 66e97bb]` 2026-07-27. First real pdq role logic.

## What landed
`pdq/present_windows.yml`: block-var path (`G:\AppRepo` from `data_disks.share.drive_letter` +
`repository.dir_name`) → `win_file` dir → 3 explicit inherited `win_acl` ACEs (BUILTIN\Users
ReadAndExecute, BUILTIN\Administrators FullControl, NT AUTHORITY\SYSTEM FullControl;
inherit=ContainerInherit,ObjectInherit) → `win_share` (Administrators full, rule_action=set,
caching=none). Defaults gain `repository.dir_name/share_name` (AppRepo).

## Cycle
P2 AGREE r3 (12→1→0): explicit Admin/SYSTEM ACEs (don't trust inheritance), Pull-copy deferred
(default Push; Deploy User NOT assumed a local admin), PDQ inheritance-hardening deferred, block-var
path, falsifiable proofs. **Director ratified SKIP_REVERT as the idempotency-proof method** (RESTART §3).
P3 Codex execute. P4: gate green after 1 key-order formatting repair (Claude); live E2E on pdq-dev —
provision G: then App Share (changed=8), SKIP_REVERT idempotency re-run changed=0; verified on-VM:
Users R&X IsInherited=false + ContainerInherit,ObjectInherit, Admins/SYSTEM Full, share
Administrators-only, CachingMode None, no INTERACTIVE ACE. P4.5 approved.

## Judgement calls
Bundled dir+ACL+share (Director); G:\AppRepo + AppRepo share (Director); explicit (not inherited)
Admin/SYSTEM ACEs; Push posture (Pull deferred); key-order fix by Claude (formatting, zero behavior).

## Deferred follow-ups
Pull Copy Mode (Deploy-User R/W grant) · PDQ repository inheritance-hardening + INTERACTIVE removal
· the pdq role reshape to consume drive-letters (drops the transitional deploy_disk_id/etc.).
