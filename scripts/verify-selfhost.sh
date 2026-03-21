#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
selfhost_verify_commands=$'
bash scripts/test-verify-all.sh
bash scripts/test-selfhost.sh
bash src/scripts/verify.sh
'
fallback_verify_commands=$'
bash scripts/test-verify-all.sh
bash scripts/test-task-manifest.sh
'

export CLASP_VERIFY_LABEL="${CLASP_VERIFY_LABEL:-verify-selfhost}"
export CLASP_VERIFY_FULL_COMMANDS="${CLASP_VERIFY_FULL_COMMANDS:-$selfhost_verify_commands}"
export CLASP_VERIFY_FALLBACK_COMMANDS="${CLASP_VERIFY_FALLBACK_COMMANDS:-$fallback_verify_commands}"

exec bash "$project_root/scripts/verify-all.sh"
