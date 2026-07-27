# CODEX-SESSION — the per-project Codex session for this repo

## ⛔ #1 HANG CAUSE — stdin drain (read this BEFORE blaming auth/model/sandbox)

**Symptom:** `codex exec` HANGS to timeout with ZERO output — looks exactly like a slow model,
a revoked token, "xhigh is too slow", or account contention. **It is almost always none of those.**

**Cause (root-caused 2026-07-16, cost ~1h of a deadline session):** `codex exec` reads the prompt
argument **and then also drains stdin** — the log line is `Reading additional input from stdin...`.
In ANY non-interactive shell (Claude's Bash tool, `run_in_background`, a pipe like `| tail`), stdin
is an open pipe that **never sends EOF**, so codex blocks on that read **forever, before the model
turn even starts**. Proven with `RUST_LOG=info`: it hangs pre-turn at the stdin read; auth 200 OK,
sandbox fine, and the actual turn (once unblocked) runs at xhigh in seconds.

**THE FIX — append `< /dev/null` to EVERY non-interactive `codex exec`:**

```bash
codex exec -p wsus -C ../.worktrees/Cxx "<prompt>" < /dev/null    # <-- ALWAYS
```

Diagnose in one shot if you ever doubt it:
```bash
RUST_LOG=info timeout 60 codex exec -p wsus "say hi" < /dev/null 2>&1 | grep -E "reasoning_effort|turn_ttft"
# healthy => you see reasoning_effort="xhigh" and a turn completing. Hang WITHOUT </dev/null => stdin.
```

Corollaries proven the same day: the model's self-report of its reasoning effort is **unreliable**
(it said "low" while telemetry said `xhigh`) — trust the otel `reasoning_effort=` line, not the
model. Long "xhigh" runs were the stdin hang wearing a costume; xhigh itself is fast for bounded tasks.

## #2 HANG CAUSE — revoked OAuth token

Only after ruling out stdin: `codex login status` cheerfully says *"Logged in using ChatGPT"* — it
only reads the local file and never asks the server. The OAuth **refresh token may be revoked**;
codex silently retries a dead websocket until the clock runs out. Confirm in one shot (WITH the
stdin fix, so you don't misdiagnose; do NOT fire more 8-minute retries):

```bash
timeout 180 codex exec -s read-only "Reply READY" < /dev/null
# revoked token =>  401 Unauthorized  on wss://.../codex/responses
#                   "Your access token could not be refreshed because your refresh token was revoked."
```

Client-side, exactly like `KEY-RELOAD.md` — **only the Director can fix it** (Claude cannot log in).

## Per-project session (Director decision, 2026-07-16)

This repo has its **own isolated Codex home** so another project's `codex login` can never clobber
this repo's token, and its session history stays self-contained. It lives **outside the git tree**
on purpose: `auth.json` is a credential, and this repo builds in git worktrees
(`../.worktrees/Cxx`), where a repo-local `.codex/` would be duplicated and could be committed.

```
CODEX_HOME=/root/.codex-homes/windows-wsus      # 700; holds auth.json + sessions + config
├── config.toml         # base: trust_level for the repo + the worktree root
└── wsus.config.toml    # the 'wsus' profile, layered via `-p wsus`
```

### The login (Director only, one-time per revocation)

```bash
CODEX_HOME=/root/.codex-homes/windows-wsus codex login
```

**Verify:**

```bash
CODEX_HOME=/root/.codex-homes/windows-wsus codex doctor    # expect: ✓ auth (not "✗ auth  no Codex credentials")
```

## How the strict-cycle invokes it

The `wsus` profile pins what every call must use, so the cycle is reproducible instead of
hand-typed flags. Validated against Codex 0.144.3's schema with `--strict-config`.

**File layout (CLI 0.144.3):** the `-p wsus` pin lives in the SEPARATE file
`/root/.codex-homes/windows-wsus/wsus.config.toml` (named `<profile>.config.toml`), NOT in a
`[profiles.wsus]` table inside `config.toml` — that legacy form now hard-errors
(`--profile wsus cannot be used while … contains legacy [profiles.wsus]`). Edit `wsus.config.toml`.

| Key | Value | Why |
|-----|-------|-----|
| `model` | `gpt-5.5` | Director 2026-07-17: moved OFF `gpt-5.6-sol` @ xhigh ("sol ultra" — burning quota fast). Head-to-head vs `gpt-5.6-luna`@xhigh on a subtle durability-flaw catch: both correct; 5.5 more thorough. **The loader-change gate still wants a Codex 5.6 (Sol) validator specifically** (`AGENTS.md` + `loader-change-protocol.md`) — that is a separate, rare governance role, not this general P2/P3 pin. |
| `model_reasoning_effort` | `xhigh` | Director-pinned — real P2/P3 run at full depth (short prompts otherwise auto-pick `low`). Confirm via otel `reasoning_effort=`, NOT the model's self-report. |
| `sandbox_mode` | `read-only` | safe default (P2 review); P3 overrides with `-s workspace-write` |
| `sandbox_workspace_write.writable_roots` | `/root/.cache`, `/root/.ansible` | `ansible-lint`/`ansible` exit before doing any work without these (was `--add-dir` by hand) |

```bash
export CODEX_HOME=/root/.codex-homes/windows-wsus

# P2 — adversarial plan review (read-only; profile default). NOTE the </dev/null (stdin fix above).
# Avoid -o <scratchpad-file>: scratchpad is outside writable_roots; capture stdout instead.
codex exec -p wsus "<review prompt>" < /dev/null

# P3 — execution in the piece's worktree (override the sandbox; writable_roots come from the profile)
codex exec -p wsus -C ../.worktrees/Cxx -s workspace-write "<execution prompt>" < /dev/null
```

**Fast bounded-audit pattern (Director 2026-07-16, "break it into 2-3 small parallel audits"):**
instead of one sprawling "verify everything" prompt, ask 2-3 razor-narrow questions (adherence /
scope / gate-logic), each `PASS|FAIL:<reason>` on line 1. Each converges in seconds at xhigh; run
them back-to-back (each `< /dev/null`). Used for the C05r P3 close-out — all three PASS in ~30s total.

## Notes

- **`--strict-config` is the config test.** It errors on any key this Codex version doesn't know
  (proven: a deliberate bogus key produced `unknown configuration field ...`). Use it after editing
  a profile — a silent typo would otherwise just be ignored.
- **Isolation is not immunity.** A per-project home stops other *projects* from overwriting this
  auth.json. It does NOT prevent an **account-level** revocation (a login elsewhere invalidating all
  refresh tokens) — that still needs the login above.
- **No long-lived shared thread** (Director, 2026-07-16): P2 must stay an INDEPENDENT adversarial
  review. A persistent thread that remembers its own past AGREEs anchors the reviewer (and bloats
  context). Each cycle gets a cold review on purpose.
- Codex sandbox still cannot commit (no ssh-agent for the signing key) — Claude commits on its
  behalf. See the `codex-driving-mechanics` memory and `RTRACK-C01`.
