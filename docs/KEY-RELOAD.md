# KEY-RELOAD — when SSH or git signing "suddenly" stops working

**Symptom:** SSH to the dev VM (or any host) fails with `Permission denied (publickey,...)`,
or `git commit` fails signing — usually right after this workstation/WSL rebooted.

**Cause:** the persistent ssh-agent survives, but it starts EMPTY after a reboot and
both private keys are passphrase-encrypted. Nothing is wrong with the server. Check
first: `ssh-add -l` — if it doesn't list the key you need, that's the whole problem.

## The two commands

```bash
ssh-add ~/.ssh/hellbomb-ssh-key     # RSA: pdq-dev / 192.168.0.182 access
ssh-add ~/.ssh/github-ssh-key       # ECDSA: commit signing and GitHub auth
```

Each prompts once for its passphrase. (One-liner variant:
`ssh-add ~/.ssh/hellbomb-ssh-key ~/.ssh/github-ssh-key`)

**Verify:**

```bash
ssh-add -l          # expect BOTH: 4096 RSA ...hellbomb... AND 521 ECDSA ...github-ssh-key
```

## Notes

- Your shell init (`~/.bashrc` / `~/.profile`) points `SSH_AUTH_SOCK` at the persistent
  agent socket (`~/.ssh/agent.sock`) and respawns the agent only when it is unreachable,
  so keys remain loaded for the session once added (verified 2026-07-15).
- Automation has the same dependency. Debug client-side with `ssh-add -l` before
  changing server configuration; `docs/VM-LIFECYCLE.md` includes the VM-side checks.
- Hands-free-after-reboot options were evaluated 2026-07-15 and deliberately deferred.
