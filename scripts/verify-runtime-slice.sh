#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
timeout_secs="${CLASP_RUNTIME_SLICE_TIMEOUT_SECS:-180}"

usage() {
  cat <<'EOF'
usage: scripts/verify-runtime-slice.sh [--list] [process|workflow|codex-loop|agent-loop|workspace|managed-loop|all ...]

Runs focused runtime and orchestration scenario verifiers for fast local
feedback before the broader verify-all path.

Slices:
  process       Process primitives: safe subprocess plus monitored stdout/stderr/exit artifacts.
                Includes the monitored run-log helper that persists status JSON and JSONL events.
  workflow      Ordinary Clasp monitored workflow with durable status/events.
  codex-loop    Ordinary Clasp program invoking codex exec directly.
  agent-loop    Ordinary Clasp builder/verifier loop using safe workspace and subprocess APIs.
  workspace     Root-bounded workspace file API from ordinary Clasp code.
  managed-loop  Native control-plane managed builder/verifier loop.

Environment:
  CLASP_RUNTIME_SLICE_TIMEOUT_SECS  Per-slice harness timeout in seconds (default: 180).
  CLASP_CLASPC and CLASPC_BIN       Resolved from this checkout and forwarded to harnesses.

Examples:
  bash scripts/verify-runtime-slice.sh process
  bash scripts/verify-runtime-slice.sh workflow codex-loop
  CLASP_RUNTIME_SLICE_TIMEOUT_SECS=240 bash scripts/verify-runtime-slice.sh all
EOF
}

list_slices() {
  printf '%s\n' process workflow codex-loop agent-loop workspace managed-loop
}

fail() {
  printf 'verify-runtime-slice: %s\n' "$*" >&2
  exit 1
}

parse_positive_timeout() {
  if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
    fail "CLASP_RUNTIME_SLICE_TIMEOUT_SECS must be a positive integer"
  fi
}

resolve_checkout_claspc() {
  local resolved_claspc_bin=""

  resolved_claspc_bin="$(
    env -u CLASP_CLASPC -u CLASPC_BIN CLASP_PROJECT_ROOT="$project_root" \
      "$project_root/scripts/resolve-claspc.sh"
  )"
  export CLASP_CLASPC="$resolved_claspc_bin"
  export CLASPC_BIN="$resolved_claspc_bin"
}

scripts_for_slice() {
  case "$1" in
    process)
      printf '%s\n' "scripts/test-monitored-step.sh"
      printf '%s\n' "scripts/test-monitored-run-log.sh"
      printf '%s\n' "scripts/test-safe-subprocess.sh"
      ;;
    workflow)
      printf '%s\n' "scripts/test-monitored-workflow.sh"
      ;;
    codex-loop)
      printf '%s\n' "scripts/test-codex-loop-program.sh"
      ;;
    agent-loop)
      printf '%s\n' "examples/agent-loop-scenario/scripts/verify.sh"
      ;;
    workspace)
      printf '%s\n' "scripts/test-safe-workspace.sh"
      ;;
    managed-loop)
      printf '%s\n' "scripts/test-swarm-native-managed-loop.sh"
      ;;
    *)
      fail "unknown runtime slice: $1"
      ;;
  esac
}

run_slice() {
  local slice="$1"
  local script_paths=()
  local script_path=""

  mapfile -t script_paths < <(scripts_for_slice "$slice")
  printf 'verify-runtime-slice: %s\n' "$slice"
  for script_path in "${script_paths[@]}"; do
    (
      cd "$project_root"
      timeout "$timeout_secs" bash "$script_path"
    )
  done
}

slices=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --list)
      list_slices
      exit 0
      ;;
    all)
      slices=(process workflow codex-loop agent-loop workspace managed-loop)
      ;;
    process|workflow|codex-loop|agent-loop|workspace|managed-loop)
      slices+=("$1")
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
  shift
done

if [[ "${#slices[@]}" == "0" ]]; then
  slices=(process workflow codex-loop agent-loop workspace)
fi

parse_positive_timeout
resolve_checkout_claspc

for slice in "${slices[@]}"; do
  run_slice "$slice"
done

printf 'verify-runtime-slice: ok (%s)\n' "${slices[*]}"
