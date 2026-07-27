# KEY-RELOAD — when SSH or git signing "suddenly" stops working

**Symptom:** SSH to the dev VM (or any host) fails with `Permission denied (publickey,...)`,
or `git commit` fails signing — usually right after this workstation/WSL rebooted.

**Cause:** the persistent ssh-agent survives, but it starts EMPTY after a reboot and
both private keys are passphrase-encrypted. Nothing is wrong with the server. Check
first: `ssh-add -l` — if it doesn't list the key you need, that's the whole problem.

## The two commands

```bash
ssh-add ~/.ssh/hellbomb-ssh-key     # 1. SSH access key  (dev VM wsus-dev / 192.168.0.181, servers)
ssh-add ~/.ssh/github-ssh-key       # 2. git signing key (commit signing + GitHub auth)
```

Each prompts once for its passphrase. (One-liner variant:
`ssh-add ~/.ssh/hellbomb-ssh-key ~/.ssh/github-ssh-key`)

**Verify:**

```bash
ssh-add -l          # expect BOTH: 4096 RSA ...hellbomb... AND 521 ECDSA ...github-ssh-key
```

## Notes

- Your shell init (`~/.bashrc` / `~/.profile`) already points `SSH_AUTH_SOCK` at the
  persistent agent socket (`~/.ssh/agent.sock`) and only respawns the agent when it is
  truly unreachable — so keys stay loaded for the whole session once added
  (the every-shell clobber bug was fixed 2026-07-15).
- Agents/automation hit the same wall: RESTART.md §4 and VM-LIFECYCLE.md §6 both point
  here. Debug client-side (`ssh-add -l`) BEFORE touching any server config.
- Hands-free-after-reboot options (Windows-agent bridge / dedicated unencrypted
  signing key) were evaluated 2026-07-15 and deliberately deferred by the Director.
