#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fast_parallel_verify_commands=$'
bash scripts/test-selfhost.sh
bash scripts/test-native-claspc.sh
bash scripts/test-native-runtime.sh
'
fast_sequential_verify_commands=$'
bash scripts/test-verify-all.sh
'
fallback_verify_commands=$'
bash scripts/test-verify-all.sh
bash scripts/test-task-manifest.sh
'

export CLASP_VERIFY_LABEL="${CLASP_VERIFY_LABEL:-verify-fast}"
export CLASP_VERIFY_PARALLEL_COMMANDS="${CLASP_VERIFY_PARALLEL_COMMANDS-$fast_parallel_verify_commands}"
export CLASP_VERIFY_SEQUENTIAL_COMMANDS="${CLASP_VERIFY_SEQUENTIAL_COMMANDS-$fast_sequential_verify_commands}"
export CLASP_VERIFY_FALLBACK_COMMANDS="${CLASP_VERIFY_FALLBACK_COMMANDS-$fallback_verify_commands}"

exec bash "$project_root/scripts/verify-all.sh"
