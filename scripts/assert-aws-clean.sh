#!/usr/bin/env bash
# Prove that no live EC2 resource or Terraform lock owned by this repository remains.
# Every AWS query is captured directly so an API/credential failure cannot masquerade as an
# empty result. The immutable repository id is the only discovery filter: malformed stack/run
# provenance must fail cleanup rather than disappear from the proof.
set -euo pipefail

: "${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID is required}"
: "${AWS_REGION:?AWS_REGION is required}"
: "${GITHUB_REPOSITORY_ID:?GITHUB_REPOSITORY_ID is required}"
: "${STATE_KEY:?STATE_KEY is required}"

aws_profile_args=()
if [ -n "${AWS_CLI_PROFILE_NAME:-}" ]; then
    aws_profile_args=(--profile "${AWS_CLI_PROFILE_NAME}")
fi

attempts="${CLEAN_PROOF_ATTEMPTS:-10}"
delay_seconds="${CLEAN_PROOF_DELAY_SECONDS:-15}"
[[ "${attempts}" =~ ^[1-9][0-9]*$ ]] || {
    echo "assert-aws-clean: CLEAN_PROOF_ATTEMPTS must be a positive integer" >&2
    exit 2
}
[[ "${delay_seconds}" =~ ^[0-9]+$ ]] || {
    echo "assert-aws-clean: CLEAN_PROOF_DELAY_SECONDS must be a non-negative integer" >&2
    exit 2
}

split_text_array() {
    local destination_name="$1" raw="$2" item
    local -n destination="${destination_name}"
    destination=()
    raw="${raw//$'\t'/$'\n'}"
    while IFS= read -r item; do
        if [ -n "${item}" ]; then
            destination+=("${item}")
        fi
    done <<< "${raw}"
}

filters=("Name=tag:RepositoryId,Values=${GITHUB_REPOSITORY_ID}")
lock_key="${STATE_KEY}.tflock"
instance_ids=()
interface_ids=()
allocation_ids=()
volume_ids=()
group_ids=()
key_ids=()

for ((attempt = 1; attempt <= attempts; attempt++)); do
    instance_text="$(aws ec2 describe-instances \
      --filters "${filters[@]}" "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
      --query 'Reservations[].Instances[].InstanceId' --output text "${aws_profile_args[@]}")"
    interface_text="$(aws ec2 describe-network-interfaces --filters "${filters[@]}" \
      --query 'NetworkInterfaces[].NetworkInterfaceId' --output text "${aws_profile_args[@]}")"
    allocation_text="$(aws ec2 describe-addresses --filters "${filters[@]}" \
      --query 'Addresses[].AllocationId' --output text "${aws_profile_args[@]}")"
    volume_text="$(aws ec2 describe-volumes --filters "${filters[@]}" \
      --query 'Volumes[].VolumeId' --output text "${aws_profile_args[@]}")"
    group_text="$(aws ec2 describe-security-groups --filters "${filters[@]}" \
      --query 'SecurityGroups[].GroupId' --output text "${aws_profile_args[@]}")"
    key_text="$(aws ec2 describe-key-pairs --filters "${filters[@]}" \
      --query 'KeyPairs[].KeyPairId' --output text "${aws_profile_args[@]}")"
    lock_json="$(aws s3api list-objects-v2 --bucket "${AWS_ACCOUNT_ID}-terraform" \
      --prefix "${lock_key}" --output json "${aws_profile_args[@]}")"

    split_text_array instance_ids "${instance_text}"
    split_text_array interface_ids "${interface_text}"
    split_text_array allocation_ids "${allocation_text}"
    split_text_array volume_ids "${volume_text}"
    split_text_array group_ids "${group_text}"
    split_text_array key_ids "${key_text}"
    lock_exists="$(jq -r --arg key "${lock_key}" \
      '[.Contents[]? | select(.Key == $key)] | length' <<< "${lock_json}")"
    [[ "${lock_exists}" =~ ^[0-9]+$ ]] || {
        echo "assert-aws-clean: could not parse Terraform lock inventory" >&2
        exit 1
    }

    remaining=$((${#instance_ids[@]} + ${#interface_ids[@]} + ${#allocation_ids[@]} + \
      ${#volume_ids[@]} + ${#group_ids[@]} + ${#key_ids[@]} + lock_exists))
    if [ "${remaining}" -eq 0 ]; then
        echo "AWS clean proof passed: no live repository-owned EC2 resource or Terraform lock remains."
        exit 0
    fi

    printf 'Attempt %d/%d: %d repository-owned resource(s)/lock remain.\n' \
      "${attempt}" "${attempts}" "${remaining}" >&2
    for description in \
      "instances:${instance_ids[*]-}" \
      "network-interfaces:${interface_ids[*]-}" \
      "elastic-ips:${allocation_ids[*]-}" \
      "volumes:${volume_ids[*]-}" \
      "security-groups:${group_ids[*]-}" \
      "key-pairs:${key_ids[*]-}"; do
        [ "${description#*:}" = '' ] || printf '  %s\n' "${description}" >&2
    done
    [ "${lock_exists}" -eq 0 ] || printf '  terraform-lock:%s\n' "${lock_key}" >&2
    if [ "${attempt}" -lt "${attempts}" ] && [ "${delay_seconds}" -gt 0 ]; then
        sleep "${delay_seconds}"
    fi
done

echo "assert-aws-clean: repository-owned resources or the Terraform lock remain" >&2
exit 1
