# KEY-RELOAD — when git signing or repository SSH authentication stops working

**Symptom:** `git commit` fails signing, or repository SSH authentication fails with
`Permission denied (publickey,...)`, usually right after this workstation/WSL rebooted.

**Cause:** the persistent ssh-agent survives, but it starts EMPTY after a reboot and
the private key is passphrase-encrypted. Nothing is wrong with the remote service. Check
first: `ssh-add -l` — if it doesn't list the key you need, that's the whole problem.

## Reload the key

```bash
ssh-add ~/.ssh/github-ssh-key       # ECDSA: commit signing and repository SSH auth
```

The command prompts once for the key's passphrase.

**Verify:**

```bash
ssh-add -l          # expect 521 ECDSA ...github-ssh-key
```

## Notes

- Your shell init (`~/.bashrc` / `~/.profile`) points `SSH_AUTH_SOCK` at the persistent
  agent socket (`~/.ssh/agent.sock`) and respawns the agent only when it is unreachable,
  so keys remain loaded for the session once added (verified 2026-07-15).
- Hands-free-after-reboot options were evaluated 2026-07-15 and deliberately deferred.
