#!/usr/bin/env bash
# Points this clone's hooks at the tracked .githooks/ directory, activating the
# repository guard hooks (banned-vocabulary scan and committer-identity check) locally.
# Run once after cloning: scripts/install-hooks.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
chmod +x .githooks/commit-msg .githooks/pre-commit
git config core.hooksPath .githooks
echo "hooks installed: core.hooksPath -> .githooks"
