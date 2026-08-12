#!/usr/bin/env bash
# =========================================================================================== #
# check-workflow-trigger.sh — assert this repo's aws-deploy.yml trigger matches the org contract
# ------------------------------------------------------------------------------------------- #
# WHY THIS EXISTS
#
# Three sibling repositories must share ONE trigger behaviour for their AWS deploy workflow. They
# drifted within an hour of the second one being written, and the drift was invisible on reading:
# one repo DECLARED `types:` while another OMITTED the key entirely. Omitting it looks like less
# configuration but means "inherit GitHub's default", which includes `synchronize` — so the two
# files behaved differently while appearing merely differently verbose.
#
# That is the same failure as two IAM defects found the same day: the semantics of an ABSENT key.
# A condition with `...IfExists` passes when the key is absent; a condition on a key invalid for a
# resource type fails when absent; an absent `types:` silently changes which events fire. Reading
# does not catch this class. Only an assertion does.
#
# The IAM sources have such an assertion and consequently never drifted. This is the equivalent
# for the workflow trigger.
#
#   ./scripts/check-workflow-trigger.sh
#
# Exit 0 = the trigger matches the contract.
# =========================================================================================== #
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WF="${ROOT}/.github/workflows/aws-deploy.yml"

# The contract, stated once. Changing intended behaviour means changing THIS, deliberately, in every
# repository — which is the point.
readonly -a REQUIRED_TYPES=(opened reopened ready_for_review synchronize)
readonly -a FORBIDDEN_TYPES=(labeled unlabeled)
readonly -a REQUIRED_PATHS=(
    'ansible/**'
    'docs/reference/aws-iam/**'
    'scripts/check-iam-literals.sh'
    'scripts/test-iam-policies.sh'
    '.github/workflows/aws-deploy.yml'
)

fail() { printf 'check-workflow-trigger: FAIL — %s\n' "$1" >&2; exit 1; }
[ -f "${WF}" ] || fail "no aws-deploy.yml at ${WF}"

PY="$(command -v python3)"
"${PY}" - "${WF}" "${REQUIRED_TYPES[*]}" "${FORBIDDEN_TYPES[*]}" "${REQUIRED_PATHS[*]}" <<'PYEOF'
import sys

wf, req_types, forbidden_types, req_paths = sys.argv[1:5]
try:
    import yaml
except ModuleNotFoundError:
    # PyYAML is not guaranteed on a bare runner; fall back to a targeted parse of the on: block so
    # the gate still runs rather than silently passing.
    yaml = None

status = 0


def bad(msg):
    global status
    print(f"check-workflow-trigger: {msg}", file=sys.stderr)
    status = 1


text = open(wf).read()
if yaml:
    doc = yaml.safe_load(text)
    # PyYAML parses the bare key `on` as the boolean True
    on = doc.get(True, doc.get("on"))
    pr = (on or {}).get("pull_request") or {}
    types = pr.get("types") or []
    paths = pr.get("paths") or []
    has_dispatch = "workflow_dispatch" in (on or {})
else:
    import re
    block = re.search(r"^on:\s*\n((?:[ \t].*\n|\n)*?)(?=^\S)", text, re.M)
    block = block.group(1) if block else ""
    m = re.search(r"types:\s*\[([^\]]*)\]", block)
    types = [t.strip() for t in m.group(1).split(",")] if m else []
    paths = re.findall(r"^\s+-\s+(\S+)\s*$", block, re.M)
    has_dispatch = "workflow_dispatch:" in block

# `types:` must be DECLARED, not inherited. An omitted key is the exact shape that caused the drift:
# it inherits a default that happens to be close to correct, so nobody notices it is not the same
# decision as the sibling repo's explicit list.
if not types:
    bad("pull_request declares no types:. Inheriting GitHub's default is how the three repos "
        "drifted — declare the list explicitly even when it matches the default.")

for t in req_types.split():
    if t not in types:
        bad(f"pull_request types must include '{t}' (missing). "
            + ("Without synchronize, editing a task file or variable in an already-open PR does "
               "not re-run the proof." if t == "synchronize" else ""))
for t in forbidden_types.split():
    if t in types:
        bad(f"pull_request types must NOT include '{t}': that path is reachable by a "
            "TRIAGE-permission user, who could spend real money without holding write access. "
            "Manual re-runs go through workflow_dispatch.")

for p in req_paths.split():
    if p not in paths:
        bad(f"paths must include '{p}' (missing).")

# terraform must be covered somehow, but HOW legitimately differs: a repo carrying a
# proxmox.tfvars alongside aws.tfvars must name aws.tfvars so a Proxmox edit cannot fire an AWS
# deploy, while a repo with no Proxmox inputs keeps terraform/** so a first real tfvars is covered
# the day it lands.
if not any(p.startswith("terraform/") for p in paths):
    bad("paths must cover terraform/ (either terraform/** or the specific AWS tfvars).")

if not has_dispatch:
    bad("workflow_dispatch must be present: it is the manual-execution path.")

sys.exit(status)
PYEOF
rc=$?
[ ${rc} -eq 0 ] || fail 'the aws-deploy.yml trigger does not match the org contract (see above).'
printf 'check-workflow-trigger: OK — types declared explicitly, synchronize present, labeled absent, paths covered.\n'
