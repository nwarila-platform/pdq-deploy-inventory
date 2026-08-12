#!/usr/bin/env bash
# =========================================================================================== #
# check-workflow-trigger.sh — assert the AWS deploy workflow's trigger contract
# ------------------------------------------------------------------------------------------- #
# WHY THIS EXISTS
#
# The deploy workflow is the only path in this repository that can obtain AWS credentials. Its
# trigger set is therefore a security control, not a convenience. Reading does not catch drift
# in this class: an ABSENT key silently inherits a default, so a file can gain or lose an entire
# execution path while looking merely differently verbose. Only an assertion catches it.
#
# The contract, stated once:
#
#   * Exactly three events: push (branches [main] only), schedule, workflow_dispatch.
#   * NO pull_request and NO pull_request_target. A fork or feature branch must never be able
#     to start a job holding id-token: write.
#   * NO path filters on push. A deploy proves the whole repository composes; skipping it
#     because a change "looked unrelated" is how a broken deploy reaches main unnoticed.
#   * Workflow-level permissions must be declared and empty; jobs elevate only what they need.
#
#   ./scripts/check-workflow-trigger.sh
#
# Exit 0 = the trigger matches the contract.
# =========================================================================================== #
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="${ROOT}/.github/workflows/aws-deploy.yml"

fail() { printf 'check-workflow-trigger: FAIL — %s\n' "$1" >&2; exit 1; }
[ -f "${WF}" ] || fail "no aws-deploy.yml at ${WF}"

python3 - "${WF}" <<'PYEOF'
import sys

wf = sys.argv[1]
status = 0


def bad(msg):
    global status
    print(f"check-workflow-trigger: {msg}", file=sys.stderr)
    status = 1


try:
    import yaml
except ModuleNotFoundError:
    print("check-workflow-trigger: PyYAML is required to parse the workflow", file=sys.stderr)
    sys.exit(1)

with open(wf) as handle:
    doc = yaml.safe_load(handle)

# PyYAML parses the bare key `on` as the boolean True unless it is quoted.
on = doc.get(True, doc.get("on"))
if not isinstance(on, dict):
    bad("the `on:` block must be a mapping of events")
    sys.exit(status)

events = set(on)
expected = {"push", "schedule", "workflow_dispatch"}
if events != expected:
    bad(
        f"events must be exactly {sorted(expected)}; got {sorted(str(e) for e in events)}. "
        "A pull_request trigger would hand credentials to unreviewed code."
    )

for forbidden in ("pull_request", "pull_request_target"):
    if forbidden in on:
        bad(
            f"`{forbidden}` must be absent: it would let a job holding id-token: write start "
            "from a ref that has not been reviewed and merged."
        )

push = on.get("push") or {}
if not isinstance(push, dict) or push.get("branches") != ["main"]:
    bad("push.branches must be exactly ['main'] — the only ref the deploy trust accepts")
if isinstance(push, dict) and ("paths" in push or "paths-ignore" in push):
    bad(
        "push must carry NO path filters: a deploy proves the whole repository composes, and a "
        "skipped deploy is how a broken main reaches production unnoticed."
    )

if "workflow_dispatch" not in on:
    bad("workflow_dispatch must be present: it is the protected break-glass execution path")

if "permissions" not in doc or doc.get("permissions") != {}:
    bad("workflow-level `permissions:` must be declared and empty ({})")

sys.exit(status)
PYEOF
rc=$?
[ ${rc} -eq 0 ] || fail 'the aws-deploy.yml trigger does not match the contract (see above).'
printf 'check-workflow-trigger: OK — push[main] + schedule + workflow_dispatch, no pull_request, no path filters.\n'
