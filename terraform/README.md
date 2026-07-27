# terraform/ — NOT ACTIVE (skeleton)

Placeholder for the eventual AWS-PoC deploy layer, mirroring `secure-wazuh`'s topology model
(ephemeral deploy → check → destroy). **Nothing here is wired yet**, deliberately:

1. **Phase order (platform model):** PHASE 1 = VMware local dev loop (current), PHASE 2 = AWS PoC,
   PHASE 3 = GitHub workflows. The role must work end-to-end on VMware before AWS is stood up.
2. **The AWS IAM must be finalized upstream first.** The AWS layer here will be *cloned* from
   `secure-wazuh`'s hardened IAM — but that IAM is still in remediation (Round 2 = CLONE-WITH-FIXES;
   see `../windows-wsus/_handoff/AWS-IAM-AUDIT-wazuh.md`). Cloning before it is CLONE-READY would
   propagate open findings. When cloning: re-derive per-repo identity (this repo's GitHub repo id,
   role/bucket names, WSUS→PDQ artifact prefixes) and do NOT copy the `<account-id>`-in-Deny pattern
   or committed VPC/SG/subnet literals — those are per-environment facts.
