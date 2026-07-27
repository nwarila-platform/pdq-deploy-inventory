#!/usr/bin/env bash
# =========================================================================================== #
# File: 'scripts/compose-and-run.sh'
# --- [ Description ] ----------------------------------------------------------------------- #
#
# Composition runner: builds the combined execution tree and runs the playbook.
#
#   1. Clones/updates nwarila-platform/ansible-framework into .compose/ansible-framework
#      and checks out the commit pinned in .framework-pin (tags once upstream releases).
#   2. Overlays this repo's roles into the framework's applications/ namespace (rsync
#      --delete so stale files never linger).
#   3. Runs the selected playbook with the framework's ansible.cfg as the chassis
#      (its roles_path resolves roles by bare name).
#
# Usage: scripts/compose-and-run.sh [-e env=int] [any extra ansible-playbook args...]
#        COMPOSE_PLAYBOOK=<name>.yml to select a playbook under ansible/playbooks/ (default pdq.yml).
#        SKIP_REVERT=1 to bypass the snapshot-revert gate (composition testing only).
#        REVERT_TO=pre-<piece> to revert to the rolling per-step snapshot instead of
#        the fresh-OS baseline (passed through to revert-vm.sh; VM-LIFECYCLE.md §2).
#
# =========================================================================================== #
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="${REPO_ROOT}/.compose"
FRAMEWORK_DIR="${COMPOSE_DIR}/ansible-framework"
FRAMEWORK_REMOTE='git@github.com:nwarila-platform/ansible-framework.git'
PIN_FILE="${REPO_ROOT}/.framework-pin"
ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-/root/.local/bin/ansible-playbook}"

[ -f "${PIN_FILE}" ] || { echo "!! missing ${PIN_FILE}" >&2; exit 1; }
PIN="$(tr -d '[:space:]' < "${PIN_FILE}")"
COMPOSE_PLAYBOOK_VALUE="${COMPOSE_PLAYBOOK-pdq.yml}"

# --- 0a. Playbook selection (fail closed before any side effect) ---------------------------- #
if [ -z "${COMPOSE_PLAYBOOK_VALUE}" ]; then
    echo "!! COMPOSE_PLAYBOOK resolved path is empty" >&2
    exit 1
fi

if [[ "${COMPOSE_PLAYBOOK_VALUE}" = /* ]]; then
    echo "!! COMPOSE_PLAYBOOK resolved path is absolute: ${COMPOSE_PLAYBOOK_VALUE}" >&2
    exit 1
fi

root_real="$(realpath -e "${REPO_ROOT}/ansible/playbooks")"
target_candidate="${root_real}/${COMPOSE_PLAYBOOK_VALUE}"
if ! target="$(realpath -e "${target_candidate}" 2>/dev/null)"; then
    echo "!! COMPOSE_PLAYBOOK resolved path does not exist: ${target_candidate}" >&2
    exit 1
fi

if [ ! -f "${target}" ]; then
    echo "!! COMPOSE_PLAYBOOK resolved path is not a file: ${target}" >&2
    exit 1
fi

case "${target}" in
    "${root_real}"/*) ;;
    *)
        echo "!! COMPOSE_PLAYBOOK resolved path escapes ${root_real}: ${target}" >&2
        exit 1
        ;;
esac
COMPOSE_PLAYBOOK_PATH="${target}"

# --- 0b. SSH mux isolation (stale ControlMaster sockets hang runs indefinitely) ------------ #
# A VM revert invalidates any live SSH multiplex socket to the guest, and a killed run can
# leave a zombie socket behind — either one stalls the next play at its first task. Keep
# Ansible's control sockets repo-local and start every run with a clean dir. (Proven: S3
# proof-out 2026-07-15 stalled on a stale ~/.ansible/cp socket; clean run after removal.)
export ANSIBLE_SSH_CONTROL_PATH_DIR="${COMPOSE_DIR}/.cp"
rm -rf "${ANSIBLE_SSH_CONTROL_PATH_DIR}"
mkdir -p "${ANSIBLE_SSH_CONTROL_PATH_DIR}"

# --- 0c. Snapshot-revert gate (discipline: clean VM before every run) ---------------------- #
if [ "${SKIP_REVERT:-0}" != "1" ]; then
    "${REPO_ROOT}/scripts/revert-vm.sh"
else
    echo ">> SKIP_REVERT=1 — running against the VM's CURRENT (possibly dirty) state."
fi

# --- 1. Framework checkout at the pin ------------------------------------------------------- #
mkdir -p "${COMPOSE_DIR}"
if [ ! -d "${FRAMEWORK_DIR}/.git" ]; then
    echo ">> Cloning ansible-framework ..."
    git clone --quiet "${FRAMEWORK_REMOTE}" "${FRAMEWORK_DIR}"
fi
git -C "${FRAMEWORK_DIR}" fetch --quiet origin
git -C "${FRAMEWORK_DIR}" checkout --quiet --detach "${PIN}"
echo ">> Framework pinned at $(git -C "${FRAMEWORK_DIR}" rev-parse --short HEAD)"

# --- 2. Overlay roles into the framework namespace ------------------------------------------ #
shopt -s nullglob
role_sources=("${REPO_ROOT}"/ansible/applications/*)
shopt -u nullglob

if [ "${#role_sources[@]}" -eq 0 ]; then
    echo "!! no role sources found under ${REPO_ROOT}/ansible/applications" >&2
    exit 1
fi

mapfile -t role_sources < <(printf '%s\n' "${role_sources[@]}" | LC_ALL=C sort)
overlaid_roles=0
validated_roles=()

# Pass 1 — VALIDATE EVERY candidate before mutating anything. Deliberately separate from the
# rsync pass: validating and overlaying in one loop lets a valid role be written to the
# framework tree before a later invalid one aborts the run, leaving a partial overlay behind.
# Same rule the composer already applies to COMPOSE_PLAYBOOK (0a) — no side effect precedes
# validation. (Claude P4 repair, WDM-0.)
for role_source in "${role_sources[@]}"; do
    role_name="$(basename "${role_source}")"

    if [[ ! "${role_name}" =~ ^[a-z][a-z0-9_]*$ ]]; then
        echo "!! invalid role basename '${role_name}' at ${role_source}" >&2
        exit 1
    fi

    # -L before -d: -d follows symlinks, so a symlink-to-dir would otherwise pass as a role
    # and rsync's trailing slash would read through it, outside the intended tree.
    if [ -L "${role_source}" ]; then
        echo "!! refusing symlinked role source: ${role_source}" >&2
        exit 1
    fi

    if [ ! -d "${role_source}" ]; then
        echo "!! role source is not a directory: ${role_source}" >&2
        exit 1
    fi

    if [ ! -f "${role_source}/tasks/main.yml" ]; then
        echo "!! role source missing tasks/main.yml: ${role_source}/tasks/main.yml" >&2
        exit 1
    fi

    # The real guard on rsync --delete: prove the destination is not a framework-OWNED role.
    # Reads the index, so a tracked-but-absent working-tree file still trips it.
    tracked_role_files="$(git -C "${FRAMEWORK_DIR}" ls-files -- "applications/${role_name}/")"
    if [ -n "${tracked_role_files}" ]; then
        echo "!! refusing to overlay framework-tracked role path: ${FRAMEWORK_DIR}/applications/${role_name}" >&2
        echo "${tracked_role_files}" >&2
        exit 1
    fi

    validated_roles+=("${role_name}")
done

# Pass 2 — overlay only after every candidate has passed.
for role_name in "${validated_roles[@]}"; do
    rsync -a --delete \
        "${REPO_ROOT}/ansible/applications/${role_name}/" \
        "${FRAMEWORK_DIR}/applications/${role_name}/"
    echo ">> Overlaid role '${role_name}' into framework applications/"
    overlaid_roles=$((overlaid_roles + 1))
done

if [ "${overlaid_roles}" -eq 0 ]; then
    echo "!! no roles overlaid into framework applications/" >&2
    exit 1
fi

# --- 3. Execute with the framework chassis --------------------------------------------------- #
cd "${FRAMEWORK_DIR}"
export ANSIBLE_CONFIG="${FRAMEWORK_DIR}/ansible.cfg"
exec "${ANSIBLE_PLAYBOOK}" \
    -i "${REPO_ROOT}/ansible/inventory/vmware.yml" \
    "${COMPOSE_PLAYBOOK_PATH}" \
    "$@"
