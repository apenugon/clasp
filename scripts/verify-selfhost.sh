#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
selfhost_parallel_verify_commands=$'
bash scripts/test-selfhost.sh
bash scripts/test-native-claspc.sh
CLASP_NATIVE_VERIFY_MODE=full bash src/scripts/verify.sh
'
selfhost_sequential_verify_commands=$'
bash scripts/test-verify-all.sh
'
fallback_verify_commands=$'
bash scripts/test-verify-all.sh
bash scripts/test-task-manifest.sh
'

export CLASP_VERIFY_LABEL="${CLASP_VERIFY_LABEL:-verify-selfhost}"
export CLASP_VERIFY_PARALLEL_COMMANDS="${CLASP_VERIFY_PARALLEL_COMMANDS-$selfhost_parallel_verify_commands}"
export CLASP_VERIFY_SEQUENTIAL_COMMANDS="${CLASP_VERIFY_SEQUENTIAL_COMMANDS-$selfhost_sequential_verify_commands}"
export CLASP_VERIFY_FALLBACK_COMMANDS="${CLASP_VERIFY_FALLBACK_COMMANDS-$fallback_verify_commands}"

exec bash "$project_root/scripts/verify-all.sh"
