#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fast_parallel_verify_commands=$'
bash scripts/test-native-claspc-diagnostics.sh
bash scripts/test-selfhost.sh
bash scripts/test-native-claspc.sh
bash scripts/test-native-runtime.sh
'
fast_sequential_verify_commands=$'
bash scripts/verify-compiler-slice.sh all
bash examples/agent-task-scenario/scripts/verify.sh
bash scripts/test-monitored-step.sh
bash scripts/test-monitored-workflow.sh
bash scripts/test-codex-loop-program.sh
bash scripts/test-verify-all.sh
bash scripts/test-verify-affected.sh
bash scripts/test-verify-compiler-slice.sh
'
fallback_verify_commands=$'
bash scripts/verify-compiler-slice.sh all
bash scripts/test-native-claspc-diagnostics.sh
bash examples/agent-task-scenario/scripts/verify.sh
bash scripts/test-monitored-step.sh
bash scripts/test-monitored-workflow.sh
bash scripts/test-codex-loop-program.sh
bash scripts/test-verify-all.sh
bash scripts/test-verify-affected.sh
bash scripts/test-verify-compiler-slice.sh
bash scripts/test-task-manifest.sh
'

export CLASP_VERIFY_LABEL="${CLASP_VERIFY_LABEL:-verify-fast}"
export CLASP_VERIFY_PARALLEL_COMMANDS="${CLASP_VERIFY_PARALLEL_COMMANDS-$fast_parallel_verify_commands}"
export CLASP_VERIFY_SEQUENTIAL_COMMANDS="${CLASP_VERIFY_SEQUENTIAL_COMMANDS-$fast_sequential_verify_commands}"
export CLASP_VERIFY_FALLBACK_COMMANDS="${CLASP_VERIFY_FALLBACK_COMMANDS-$fallback_verify_commands}"

if [[ -z "${CLASP_CLASPC:-}" && -z "${CLASPC_BIN:-}" ]]; then
  resolved_claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
  export CLASP_CLASPC="$resolved_claspc_bin"
  export CLASPC_BIN="$resolved_claspc_bin"
fi

exec bash "$project_root/scripts/verify-all.sh"
