#!/usr/bin/env bash
# ============================================================================================= #
# File: 'scripts/converge-held-bed.sh'
# --- [ Description ] ------------------------------------------------------------------------- #
#
# Runs the playbook against a bed a workflow is HOLDING, from this workstation.
#
# A full deploy-converge-destroy is roughly forty minutes, which is the wrong feedback loop for
# writing a region. This targets a bed that is already up: craft a region, converge, read the
# recap, craft the next one. Minutes instead of a redeployment.
#
# The dynamic inventory selects a bed by the four tags the workflow stamps on it, read from the
# environment. Nothing here reimplements that -- it exports what the inventory already looks for
# and hands the run to compose-and-run.sh, so a local converge is the same composition CI does.
#
# --- [ How To Call It ] ---------------------------------------------------------------------- #
#   scripts/converge-held-bed.sh                 # newest held run
#   scripts/converge-held-bed.sh 33550502392     # a specific run id
#   RUN_ARGS='-e state=absent' scripts/converge-held-bed.sh
#
# ============================================================================================= #
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY='nwarila-platform/pdq-deploy-inventory'

# The run whose bed to talk to. Named explicitly, or the newest deploy still running -- a
# finished run has destroyed its bed, so it is never the answer.
run_id="${1-}"
if [ -z "${run_id}" ]; then
  run_id="$(gh run list --repo "${REPOSITORY}" --workflow aws-deploy.yml --status in_progress \
    --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)"
fi
if [ -z "${run_id}" ] || [ "${run_id}" = 'null' ]; then
  echo "!! no deploy run is holding a bed; dispatch one with hold_minutes and wait for it" >&2
  exit 1
fi

# The inventory reads these four and nothing else; ENVIRONMENT defaults to test in the plugin.
export GITHUB_REPOSITORY="${REPOSITORY}"
export GITHUB_REPOSITORY_ID="$(gh api "repos/${REPOSITORY}" --jq .id)"
export GITHUB_RUN_ID="${run_id}"
export ENVIRONMENT="${ENVIRONMENT:-test}"
# The launch key pair, whose private half CI stages per run and an operator already holds.
export CI_PRIVATE_KEY="${CI_PRIVATE_KEY:-${HOME}/.ssh/nwarila-ec2-key}"

if [ ! -r "${CI_PRIVATE_KEY}" ]; then
  echo "!! cannot read the launch key at ${CI_PRIVATE_KEY}" >&2
  exit 1
fi

account_id="$(aws sts get-caller-identity --query Account --output text)"

echo ">> Bed from run ${GITHUB_RUN_ID}"
# The overlay is rsynced INTO the framework checkout and left there, so the next run's framework
# materializer trips over this repository's stubs before the overlay is refreshed. Clearing it is
# what makes a second invocation behave like the first.
find "${REPO_ROOT}/.compose/ansible-framework/applications" -maxdepth 1 -name 'pdq_*' \
  -exec rm -rf {} + 2>/dev/null || true

# COMPOSE_INVENTORY is REPOSITORY-RELATIVE: compose-and-run.sh refuses an absolute path outright,
# so naming one here would fail every call before a single task ran.
COMPOSE_PLAYBOOK='pdq-aws.yml' \
COMPOSE_INVENTORY='ansible/inventory/aws_ec2.yml' \
  "${REPO_ROOT}/scripts/compose-and-run.sh" \
    -e "env=${ENVIRONMENT}" \
    -e "aws_account_id=${account_id}" \
    -e "aws_region=${AWS_REGION:-us-east-1}" \
    ${RUN_ARGS-} "${@:2}"
