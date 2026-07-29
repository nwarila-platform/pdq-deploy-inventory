#!/usr/bin/env bash
# =========================================================================================== #
# check-iam-literals.sh — the substitution gate for docs/reference/aws-iam/
# ------------------------------------------------------------------------------------------- #
# WHY THIS EXISTS
#
# The AWS IAM pattern in this repo was cloned from a sibling. Four independent audit rounds
# (see _handoff/AWS-IAM-AUDIT-wazuh.md) found that the dangerous clone failure is NOT a total
# substitution miss — that fails closed and loudly. It is a PARTIAL miss: a foreign repository
# identity or state prefix left behind in one statement, which silently grants this repo
# authority over a SIBLING's live resources in the shared AWS account, while this repo's own
# deploy still works. Reading an applied policy back and diffing it against the materialized
# source cannot catch that, because the materialized source is what is wrong.
#
# This gate is the mechanical answer. It has two modes.
#
#   repo mode (default)     Run against the tracked sources. Placeholders MUST be present and
#                           foreign literals MUST NOT be. This is the CI gate.
#
#   materialized mode       Run against an untracked, substituted directory just before any
#                           `aws iam` call. NO placeholder may remain.
#                             ./scripts/check-iam-literals.sh --materialized <dir>
#
# Exit 0 = safe to proceed. Any other exit = do not apply.
# =========================================================================================== #
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IAM_DIR="${REPO_ROOT}/docs/reference/aws-iam"

# This repository's own identity. Everything else in the org is "foreign".
readonly THIS_REPO='pdq-deploy-inventory'

# IDENTITY literals belong to a SIBLING REPOSITORY. They are never correct here, in a source or in
# a materialized copy, so they are rejected in both modes. A hit is the partial-substitution failure
# this gate exists to stop.
readonly -a FOREIGN_IDENTITY_PATTERNS=(
    'secure-wazuh'
    'wazuh'
    'windows-wsus'
    '1316209092'               # windows-wsus repository id — a partial substitution with a SIBLING's
                              # id is the fail-open case this gate exists for, and the
                              # twelve-digit account rule does not catch a 10-digit id
    '1307854438'              # secure-wazuh repository id — the sharpest fail-open of the audit
    '230745524'               # nwarila-platform owner id (only ever appeared in a dead subject)
    'sg-06a3a06bcc4413c10'    # secure-wazuh's retired standing security group
    'sgr-08833db7ea5d82c23'
    'aws-marketplace'         # open publisher namespace; this repo launches amazon-alias images
)

# ENVIRONMENT literals name shared account infrastructure. Verified 2026-07-29: this account has a
# SINGLE VPC and subnet, and `alias/aws/ebs` resolves to one account-wide AWS-managed key — so every
# repository here legitimately materializes the SAME values. They are therefore rejected in the
# SOURCES ONLY (which must carry placeholders) and accepted in a materialized copy, where they are
# the correct answer rather than a leftover.
readonly -a ENVIRONMENT_PATTERNS=(
    'vpc-03c38504869c1c9bb'
    'subnet-0e1c8aae192deff26'
    '381209c1-5530-4c19-8f9d-5d75e401790b'
)

# Placeholders this repo's sources are REQUIRED to still carry. Each is an opaque per-environment
# value that a reviewer cannot eyeball as wrong, so it must never be committed concrete.
readonly -a REQUIRED_PLACEHOLDERS=(
    '<account-id>'
    '<repository-id>'
    '<region>'
    '<vpc-id>'
    '<subnet-id>'
    '<ebs-kms-key-id>'
    '<key-pair-name>'
)

fail() { printf 'check-iam-literals: FAIL — %s\n' "$1" >&2; exit 1; }

[ -d "${IAM_DIR}" ] || fail "no IAM source directory at ${IAM_DIR}"

# --------------------------------------------------------------------------------------------
# Materialized mode: the substituted copy must contain NO placeholder at all.
# --------------------------------------------------------------------------------------------
if [ "${1:-}" = '--materialized' ]; then
    target="${2:-}"
    [ -n "${target}" ] && [ -d "${target}" ] || fail 'usage: --materialized <existing-directory>'

    if grep -RIn --binary-files=without-match -E '<[a-z][a-z0-9-]*>' "${target}"; then
        fail 'the materialized tree still contains placeholders (listed above). Do not apply.'
    fi
    for pattern in "${FOREIGN_IDENTITY_PATTERNS[@]}"; do
        if grep -RIn --binary-files=without-match -F "${pattern}" "${target}"; then
            fail "the materialized tree contains the sibling-identity literal '${pattern}' (listed above)."
        fi
    done
    printf 'check-iam-literals: OK — materialized tree is fully substituted and carries no sibling identity.\n'
    exit 0
fi

# --------------------------------------------------------------------------------------------
# Repo mode: no foreign literal, no real account id, every required placeholder still present.
# --------------------------------------------------------------------------------------------
status=0

# Foreign literals are checked against the APPLIED artifacts only — the policy and trust documents
# that reach AWS. Prose in README.md must stay free to name the repository this pattern was cloned
# from and to warn about traps by name; that provenance is worth more than a blanket match, and a
# comment never became an authorization boundary.
readonly -a APPLY_DIRS=("${IAM_DIR}/policies" "${IAM_DIR}/roles")
for dir in "${APPLY_DIRS[@]}"; do
    [ -d "${dir}" ] || fail "missing ${dir}"
done

for pattern in "${FOREIGN_IDENTITY_PATTERNS[@]}" "${ENVIRONMENT_PATTERNS[@]}"; do
    if grep -RIn --binary-files=without-match -F "${pattern}" "${APPLY_DIRS[@]}"; then
        printf 'check-iam-literals: literal "%s" must not appear in a committed document — use a placeholder.\n' "${pattern}" >&2
        status=1
    fi
done

# A real AWS account id is twelve consecutive digits. It must never be committed ANYWHERE under
# this tree — documentation included — because the <account-id> placeholder is the only tripwire
# that keeps it out of git.
if grep -RIn --binary-files=without-match -E '[0-9]{12}' "${IAM_DIR}"; then
    printf 'check-iam-literals: a twelve-digit value looks like a real AWS account id. Use <account-id>.\n' >&2
    status=1
fi

for placeholder in "${REQUIRED_PLACEHOLDERS[@]}"; do
    if ! grep -RIq --binary-files=without-match -F "${placeholder}" "${APPLY_DIRS[@]}"; then
        printf 'check-iam-literals: required placeholder %s is absent — it was substituted in a committed file.\n' "${placeholder}" >&2
        status=1
    fi
done

# Every JSON document must parse, and every policy/trust must name this repository somewhere so
# a wholesale copy from a sibling cannot pass silently.
while IFS= read -r document; do
    python3 -S -c "import json,sys; json.load(open(sys.argv[1]))" "${document}" \
        || { printf 'check-iam-literals: %s is not valid JSON.\n' "${document}" >&2; status=1; }
done < <(find "${IAM_DIR}" -type f -name '*.json')

if ! grep -RIq --binary-files=without-match -F "${THIS_REPO}" "${APPLY_DIRS[@]}"; then
    printf 'check-iam-literals: no source names this repository (%s).\n' "${THIS_REPO}" >&2
    status=1
fi

[ "${status}" -eq 0 ] || fail 'the IAM sources are not clone-safe (see the findings above).'
printf 'check-iam-literals: OK — no foreign literal, no committed account id, all %d placeholders intact.\n' \
    "${#REQUIRED_PLACEHOLDERS[@]}"
