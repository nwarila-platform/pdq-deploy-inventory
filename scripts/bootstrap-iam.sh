#!/usr/bin/env bash
# =========================================================================================== #
# bootstrap-iam.sh — materialize and apply this repository's AWS IAM
# ------------------------------------------------------------------------------------------- #
# Creates the deploy boundary this repository declares: five customer-managed policies, three
# roles, and the EC2 instance profile. Idempotent — re-running reconciles rather than duplicates,
# so it is safe to run after editing a source document.
#
#   ./scripts/bootstrap-iam.sh [--apply] [aws-profile]
#
# Without --apply it PLANS: materializes, gates, validates every document through Access
# Analyzer, and prints what would be created or updated. Nothing is written to AWS.
# With --apply it additionally creates/updates and then verifies against the live principal.
#
# Substitution values are resolved from the live account and the live GitHub repository, never
# hand-typed: the account from sts, the repository id from the GitHub API, the EBS key from the
# alias, and the VPC/subnet from the deploy environment. A key pair is NOT created here — it
# carries private key material whose custody is an operator decision.
# =========================================================================================== #
set -uo pipefail

APPLY=false; [ "${1:-}" = '--apply' ] && { APPLY=true; shift; }
PROFILE="${1:-admin}"
REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IAM_DIR="${ROOT}/docs/reference/aws-iam"
OWNER='nwarila-platform'
REPO="$(basename "${ROOT}")"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
say() { printf '  %-52s %s\n' "$1" "$2"; }
die() { printf 'bootstrap-iam: FAIL — %s\n' "$1" >&2; exit 1; }

echo "== resolving substitution values from live sources =="
ACCOUNT="$(aws sts get-caller-identity --profile "${PROFILE}" --query Account --output text)" || die 'no AWS identity'
REPO_ID="$(gh api "repos/${OWNER}/${REPO}" --jq .id)" || die "GitHub repo ${OWNER}/${REPO} not found"
KMS_KEY="$(aws kms describe-key --key-id alias/aws/ebs --profile "${PROFILE}" --region "${REGION}" \
           --query 'KeyMetadata.KeyId' --output text)" || die 'alias/aws/ebs unresolved'
VPC_ID="$(aws ec2 describe-vpcs --profile "${PROFILE}" --region "${REGION}" --query 'Vpcs[0].VpcId' --output text)"
SUBNET_ID="$(aws ec2 describe-subnets --profile "${PROFILE}" --region "${REGION}" --query 'Subnets[0].SubnetId' --output text)"
KEY_PAIR="${REPO}-poc-key"
say 'repository id' "${REPO_ID}"
say 'vpc / subnet' "${VPC_ID} / ${SUBNET_ID}"
say 'ebs key' "${KMS_KEY}"

echo "== materialize =="
mkdir -p "${WORK}/policies" "${WORK}/roles"
cp "${IAM_DIR}/policies/"*.json "${WORK}/policies/"
cp "${IAM_DIR}/roles/"*.json    "${WORK}/roles/"
sed -i "s|<account-id>|${ACCOUNT}|g; s|<repository-id>|${REPO_ID}|g; s|<region>|${REGION}|g;
        s|<vpc-id>|${VPC_ID}|g; s|<subnet-id>|${SUBNET_ID}|g; s|<ebs-kms-key-id>|${KMS_KEY}|g;
        s|<key-pair-name>|${KEY_PAIR}|g" "${WORK}"/policies/*.json "${WORK}"/roles/*.json

"${ROOT}/scripts/check-iam-literals.sh" --materialized "${WORK}" >/dev/null \
  || die 'the materialized tree failed the substitution gate — do not apply'
say 'substitution gate' 'clean'

echo "== validate every document before anything is written =="
for f in "${WORK}"/policies/*.json; do
    n="$(aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY --policy-document "file://${f}" \
         --profile "${PROFILE}" --region "${REGION}" \
         --query 'length(findings[?findingType==`ERROR`||findingType==`SECURITY_WARNING`])' --output text)"
    [ "${n}" = 0 ] || die "$(basename "${f}") has ${n} error/security finding(s)"
    say "$(basename "${f}")" 'clean'
done
for f in "${WORK}"/roles/*.json; do
    n="$(aws accessanalyzer validate-policy --policy-type RESOURCE_POLICY --policy-document "file://${f}" \
         --profile "${PROFILE}" --region "${REGION}" \
         --query 'length(findings[?findingType==`ERROR`&&issueCode!=`MISSING_RESOURCE`])' --output text)"
    [ "${n}" = 0 ] || die "$(basename "${f}") has ${n} error(s)"
    say "$(basename "${f}")" 'clean'
done

# ---- the declared object model -------------------------------------------------------------
CI_ROLE="github_${OWNER}_${REPO}"
ADMIN_ROLE="github_${OWNER}_${REPO}-admin"
POC_ROLE="${REPO}-poc-role"
POC_PROFILE="${REPO}-poc-profile"
# policy file -> applied name (file basename IS the applied name, per this repo's convention)
mapfile -t POLICIES < <(cd "${WORK}/policies" && ls *.json | sed 's/\.json$//')
DEPLOY_POLICIES=(); STATE_POLICY=''
for p in "${POLICIES[@]}"; do
    case "${p}" in
        github_*) STATE_POLICY="${p}" ;;
        *) DEPLOY_POLICIES+=("${p}") ;;
    esac
done

echo "== plan =="
exists_policy() { aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT}:policy/$1" --profile "${PROFILE}" >/dev/null 2>&1; }
exists_role()   { aws iam get-role --role-name "$1" --profile "${PROFILE}" >/dev/null 2>&1; }
for p in "${POLICIES[@]}"; do say "policy ${p}" "$(exists_policy "${p}" && echo 'exists → new version' || echo 'CREATE')"; done
for r in "${CI_ROLE}" "${ADMIN_ROLE}" "${POC_ROLE}"; do say "role ${r}" "$(exists_role "${r}" && echo 'exists → update trust' || echo 'CREATE')"; done
say "instance profile ${POC_PROFILE}" "$(aws iam get-instance-profile --instance-profile-name "${POC_PROFILE}" --profile "${PROFILE}" >/dev/null 2>&1 && echo exists || echo CREATE)"

if ! ${APPLY}; then
    printf '\nbootstrap-iam: PLAN ONLY — nothing was written. Re-run with --apply.\n'
    exit 0
fi

echo "== apply =="
for p in "${POLICIES[@]}"; do
    arn="arn:aws:iam::${ACCOUNT}:policy/${p}"
    if exists_policy "${p}"; then
        # keep at most 5 versions: prune the oldest non-default before adding
        old="$(aws iam list-policy-versions --policy-arn "${arn}" --profile "${PROFILE}" \
               --query 'Versions[?!IsDefaultVersion]|[-1].VersionId' --output text 2>/dev/null)"
        [ "${old}" != 'None' ] && [ -n "${old}" ] && \
          [ "$(aws iam list-policy-versions --policy-arn "${arn}" --profile "${PROFILE}" --query 'length(Versions)' --output text)" -ge 5 ] && \
          aws iam delete-policy-version --policy-arn "${arn}" --version-id "${old}" --profile "${PROFILE}" >/dev/null 2>&1
        aws iam create-policy-version --policy-arn "${arn}" --policy-document "file://${WORK}/policies/${p}.json" \
            --set-as-default --profile "${PROFILE}" >/dev/null && say "policy ${p}" 'new default version'
    else
        aws iam create-policy --policy-name "${p}" --policy-document "file://${WORK}/policies/${p}.json" \
            --description "${REPO} deploy boundary - see docs/reference/aws-iam" --profile "${PROFILE}" >/dev/null \
            && say "policy ${p}" 'created'
    fi
done

apply_role() { # role-name trust-file
    local name="$1" trust="$2"
    if exists_role "${name}"; then
        aws iam update-assume-role-policy --role-name "${name}" --policy-document "file://${trust}" --profile "${PROFILE}" >/dev/null \
            && say "role ${name}" 'trust updated'
    else
        aws iam create-role --role-name "${name}" --assume-role-policy-document "file://${trust}" \
            --max-session-duration 3600 --description "${REPO} - see docs/reference/aws-iam" --profile "${PROFILE}" >/dev/null \
            && say "role ${name}" 'created'
    fi
}
apply_role "${CI_ROLE}"    "${WORK}/roles/github_${OWNER}_${REPO}.trust.json"
apply_role "${ADMIN_ROLE}" "${WORK}/roles/github_${OWNER}_${REPO}-admin.trust.json"
apply_role "${POC_ROLE}"   "${WORK}/roles/${REPO}-poc-role.trust.json"

attach() {
    aws iam attach-role-policy --role-name "$1" --policy-arn "$2" --profile "${PROFILE}" >/dev/null 2>&1 \
        || die "could not attach $(basename "$2") to $1 - the role may not exist"
}
for p in "${DEPLOY_POLICIES[@]}"; do
    attach "${CI_ROLE}"    "arn:aws:iam::${ACCOUNT}:policy/${p}"
    attach "${ADMIN_ROLE}" "arn:aws:iam::${ACCOUNT}:policy/${p}"
done
# the state policy goes to BOTH: the admin role's documented local deploy path cannot reach
# Terraform state without it.
attach "${CI_ROLE}"    "arn:aws:iam::${ACCOUNT}:policy/${STATE_POLICY}"
attach "${ADMIN_ROLE}" "arn:aws:iam::${ACCOUNT}:policy/${STATE_POLICY}"
attach "${POC_ROLE}"   'arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore'
say 'attachments' 'reconciled'

if ! aws iam get-instance-profile --instance-profile-name "${POC_PROFILE}" --profile "${PROFILE}" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "${POC_PROFILE}" --profile "${PROFILE}" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "${POC_PROFILE}" --role-name "${POC_ROLE}" --profile "${PROFILE}" >/dev/null
    say "instance profile ${POC_PROFILE}" 'created'
fi

echo "== verify against the LIVE principal =="
sp() { aws iam simulate-principal-policy --policy-source-arn "arn:aws:iam::${ACCOUNT}:role/${CI_ROLE}" \
       --action-names "$1" --resource-arns "$2" --context-entries "${@:3}" --profile "${PROFILE}" --region "${REGION}" \
       --query 'EvaluationResults[0].EvalDecision' --output text 2>&1 | tail -1; }
TAGK='ContextKeyName=ec2:ResourceTag/nwarila:management:repository-id,ContextKeyType=string,ContextKeyValues'
REGK="ContextKeyName=aws:RequestedRegion,ContextKeyType=string,ContextKeyValues=${REGION}"
say 'terminate own tagged instance' "$(sp ec2:TerminateInstances "arn:aws:ec2:${REGION}:${ACCOUNT}:instance/i-0a" "${REGK}" "${TAGK}=${REPO_ID}")"
say 'terminate secure-wazuh instance' "$(sp ec2:TerminateInstances "arn:aws:ec2:${REGION}:${ACCOUNT}:instance/i-0b" "${REGK}" "${TAGK}=1307854438")"
say 'iam:AttachRolePolicy (escalation probe)' "$(sp iam:AttachRolePolicy "arn:aws:iam::${ACCOUNT}:role/${POC_ROLE}" "${REGK}")"
printf '\nbootstrap-iam: applied. A key pair (%s) is NOT created here — it carries private key\nmaterial whose custody is an operator decision.\n' "${KEY_PAIR}"
