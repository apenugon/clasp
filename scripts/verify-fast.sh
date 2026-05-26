#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
affected_mode=0
affected_args=()
verify_report_json_arg=""

usage() {
  cat <<'EOF'
usage: scripts/verify-fast.sh [--help]
       scripts/verify-fast.sh [--report-json PATH]
       scripts/verify-fast.sh --affected [verify-affected options]
       scripts/verify-fast.sh --changed-file PATH [--changed-file PATH ...] [verify-affected options]

Runs the fast local verification bundle for agent iteration. This preserves
scripts/verify-all.sh as the full final gate while skipping benchmark-wide and
repo-wide probes that are not useful in the normal builder loop.

When changed files are known, pass --changed-file, --files-from, or --affected
to route through scripts/verify-affected.sh. That path selects the smallest
focused verifier plan it can, falling back to this fast bundle for unknown or
empty inputs.

Forwarded affected-mode options:
  --changed-file PATH
  --files-from PATH
  --report-json PATH
  --plan-only

Environment:
  CLASP_VERIFY_REPORT_JSON      Write a timing/report JSON for the fast bundle.
  CLASP_VERIFY_PARALLEL_JOBS    Override parallel job count used by verify-all.
  CLASP_VERIFY_MAX_PARALLEL_JOBS
                                Cap verify-all's effective parallel job count.
  CLASP_VERIFY_MANAGED          Set to 0 to bypass verify-all's managed memory guard.
  CLASP_CLASPC or CLASPC_BIN    Ignored when resolving this checkout's claspc.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --affected)
      affected_mode=1
      shift
      ;;
    --changed-file|--files-from|--report-json)
      if [[ $# -lt 2 ]]; then
        printf 'verify-fast: %s requires a value\n' "$1" >&2
        exit 2
      fi
      if [[ "$1" == "--report-json" ]]; then
        verify_report_json_arg="$2"
      else
        affected_mode=1
      fi
      affected_args+=("$1" "$2")
      shift 2
      ;;
    --changed-file=*|--files-from=*|--report-json=*)
      if [[ "$1" == --report-json=* ]]; then
        verify_report_json_arg="${1#--report-json=}"
      else
        affected_mode=1
      fi
      affected_args+=("$1")
      shift
      ;;
    --plan-only)
      affected_mode=1
      affected_args+=("$1")
      shift
      ;;
    *)
      printf 'verify-fast: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$affected_mode" == "1" ]]; then
  exec bash "$project_root/scripts/verify-affected.sh" "${affected_args[@]}"
fi

if [[ -n "$verify_report_json_arg" ]]; then
  export CLASP_VERIFY_REPORT_JSON="$verify_report_json_arg"
fi

fast_parallel_verify_commands=$'
bash scripts/test-native-claspc-diagnostics.sh
bash src/scripts/verify.sh
bash scripts/test-source-run-cache.sh
bash scripts/test-promoted-source-export-cache.sh
bash scripts/test-int-builtins.sh
bash scripts/test-dict-builtins.sh
bash scripts/test-native-runtime-smoke.sh
bash scripts/test-native-claspc-smoke.sh
bash scripts/test-managed-job.sh
'
fast_sequential_verify_commands=$'
bash scripts/verify-compiler-slice.sh all
bash scripts/test-record-update-parity.sh
bash scripts/verify-runtime-slice.sh process workflow codex-loop agent-loop workspace
bash examples/agent-metadata/scripts/verify.sh
bash examples/agent-task-scenario/scripts/verify.sh
bash scripts/test-js-process-runtime.sh
bash scripts/test-js-emitter-determinism.sh
bash scripts/test-unsafe-quarantine.sh
bash scripts/test-verify-all-smoke.sh
bash scripts/test-verify-affected.sh
bash scripts/test-verify-compiler-slice.sh
bash scripts/test-verify-runtime-slice.sh
'
fallback_verify_commands=$'
bash scripts/verify-compiler-slice.sh all
bash scripts/test-record-update-parity.sh
bash scripts/verify-runtime-slice.sh process workflow codex-loop agent-loop workspace
bash src/scripts/verify.sh
bash scripts/test-native-claspc-diagnostics.sh
bash scripts/test-int-builtins.sh
bash scripts/test-dict-builtins.sh
bash scripts/test-native-runtime-smoke.sh
bash scripts/test-native-claspc-smoke.sh
bash scripts/test-managed-job.sh
bash scripts/test-promoted-source-export-cache.sh
bash scripts/test-unsafe-quarantine.sh
bash examples/agent-metadata/scripts/verify.sh
bash examples/agent-task-scenario/scripts/verify.sh
bash scripts/test-js-emitter-determinism.sh
bash scripts/test-verify-all-smoke.sh
bash scripts/test-verify-affected.sh
bash scripts/test-verify-compiler-slice.sh
bash scripts/test-verify-runtime-slice.sh
bash scripts/test-task-manifest.sh
'

export CLASP_VERIFY_LABEL="${CLASP_VERIFY_LABEL:-verify-fast}"
export CLASP_VERIFY_PARALLEL_COMMANDS="${CLASP_VERIFY_PARALLEL_COMMANDS-$fast_parallel_verify_commands}"
export CLASP_VERIFY_SEQUENTIAL_COMMANDS="${CLASP_VERIFY_SEQUENTIAL_COMMANDS-$fast_sequential_verify_commands}"
export CLASP_VERIFY_FALLBACK_COMMANDS="${CLASP_VERIFY_FALLBACK_COMMANDS-$fallback_verify_commands}"

resolved_claspc_bin="$(
  env -u CLASP_CLASPC -u CLASPC_BIN CLASP_PROJECT_ROOT="$project_root" \
    "$project_root/scripts/resolve-claspc.sh"
)"
export CLASP_CLASPC="$resolved_claspc_bin"
export CLASPC_BIN="$resolved_claspc_bin"

exec bash "$project_root/scripts/verify-all.sh"
