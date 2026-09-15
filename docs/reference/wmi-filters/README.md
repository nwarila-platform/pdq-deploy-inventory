# WMI filters

**None.** Checked against the live directory on 2026-09-03: no `msWMI-Som` objects exist in
`tcn.trinitytechnicalservices.com`.

The directory has three GPOs — `Default Domain Policy`, `Default Domain Controllers Policy` and
`WorkSpaces Remote Management` — and none of them is scoped by a WMI filter. Targeting is done
with OU links instead, which is what `pdq_ad_config` relies on: the LAPS read grant is an ACL on
`OU=Domain Workstations` and `OU=Domain Servers`, and a machine is governed by where it is filed.

This directory is kept so the absence is a recorded finding rather than an unanswered question.
Add a filter's export here if one is ever introduced.
