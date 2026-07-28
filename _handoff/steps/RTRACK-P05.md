# RTRACK-P05 — Background Service User (local svc-pdq + Administrators + Log-On-as-Service)

**Merged** `ad26a08 [audited 0509401]` 2026-07-28. First secret-bearing pdq piece.

## What landed
`pdq/present_windows.yml`: a Background Service User region INSERTED BEFORE the App Share region —
`win_user` (name `config.service_account.name` = svc-pdq, UNQUALIFIED; `no_log` password; state=present;
groups=[Administrators] groups_action=add; password_never_expires; user_cannot_change_password;
update_password=on_create) → `win_user_right` (SeServiceLogonRight, users=['.\svc-pdq'] LOCAL-QUALIFIED,
action=add). README gains a Background Service User section (secret supply via vault / `-e @<file>`,
`no_log`, the update_password=on_create rotation caveat, local-only scope). No defaults added —
`service_account` lives in the `pdq:` override dict.

## Cycle
P2 **AGREE r2** (r1 REVISE, 12 pts folded): local-account-ONLY scope (domain = future design change,
not a name override); secedit-**SID** proof; `-e @<non-committed file>` carrying the COMPLETE pdq dict
as the secret supply — NEVER a literal `-e` (shell history / process list / logs bypass task no_log);
LOCAL-QUALIFIED `.\svc-pdq` for the right (win_user itself unqualified); update_password=on_create for
idempotency; `no_log: true` on the win_user task. P3 Codex execute (worktree `build/P05`, allowlist-only).
P4: gate green (yamllint 0 / ansible-lint 0 / splitargs 0 / syntax clean); live E2E on pdq-dev
(revert-first) create changed=10 failed=0; verified `svc-pdq` Enabled, PasswordExpires=**never**,
UserMayChange=**False**, in **Administrators**, **SeServiceLogonRight granted**; SKIP_REVERT idempotency
re-run **changed=0**; secret hygiene — default-verbosity run **0** sentinel leaks (win_user no_log honored).
Two P4 **proof-script** bugs found + corrected (queried non-existent `PasswordNeverExpires` LocalUser
property → use `PasswordExpires` null=never; secedit records the right by NAME `svc-pdq` not `*SID` →
assert name OR SID) — **role behavior was correct**, only the assertions were wrong. P4.5 approved.

## Judgement calls
LOCAL svc-pdq only (Director 2026-07-27 + Codex #11); win_user_right local-qualified `.\svc-pdq`, win_user
unqualified (Codex #2); repository R/W via Administrators membership + P03's BUILTIN\Administrators
FullControl ACE — no per-account App Share ACE (Codex #7); update_password=on_create — a password
ROTATION is deliberately ignored for an existing account (Codex #1); pre-grant Log-On-as-Service
(idempotent + explicit) rather than relying on PDQ's install-time auto-grant.

## Finding → TD-005 (framework governance)
The v3 loader's `INIT | Loading Overrides` `set_fact` publishes the merged `<role>_running` (a
style-guide-SANCTIONED set_fact — R3's named exception). With a secret now in the dict it becomes a
persistent host fact printed at `-v`. Default verbosity is clean; the win_user task's own `no_log` works.
The fix (`no_log` the loader's config set_fact) is loader governance surface → **loader-change-protocol**
(Fable + Sol gate + Director acceptance). Logged **TD-005**. P05 introduces no fix (loader untouchable
per-role). The Director's "isn't set_fact banned?" check confirmed the loader use is R3's SANCTIONED
exception (not a violation) and that P05's own code uses zero set_fact.

## Deferred follow-ups
loader `no_log` for the secret-bearing merged config (TD-005 / loader-change-protocol) · the pdq role
reshape to consume drive-letters (drops the transitional `deploy_disk_id`/`inventory_disk_id`/`share_disk_id`) ·
Pull-Copy mode (Deploy-User R/W grant) · PDQ repository inheritance-hardening.
