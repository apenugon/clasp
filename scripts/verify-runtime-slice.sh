#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
timeout_secs="${CLASP_RUNTIME_SLICE_TIMEOUT_SECS:-180}"

usage() {
  cat <<'EOF'
usage: scripts/verify-runtime-slice.sh [--list] [process|workflow|codex-loop|managed-loop|all ...]

Runs focused runtime and orchestration scenario verifiers for fast local
feedback before the broader verify-all path.

Slices:
  process       Monitored process step: stdout/stderr/exit/heartbeat artifacts.
  workflow      Ordinary Clasp monitored workflow with durable status/events.
  codex-loop    Ordinary Clasp program invoking codex exec directly.
  managed-loop  Native control-plane managed builder/verifier loop.

Environment:
  CLASP_RUNTIME_SLICE_TIMEOUT_SECS  Per-slice harness timeout in seconds (default: 180).
  CLASP_CLASPC or CLASPC_BIN        Optional explicit claspc binary forwarded to harnesses.

Examples:
  bash scripts/verify-runtime-slice.sh process
  bash scripts/verify-runtime-slice.sh workflow codex-loop
  CLASP_RUNTIME_SLICE_TIMEOUT_SECS=240 bash scripts/verify-runtime-slice.sh all
EOF
}

list_slices() {
  printf '%s\n' process workflow codex-loop managed-loop
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

script_for_slice() {
  case "$1" in
    process)
      printf '%s\n' "scripts/test-monitored-step.sh"
      ;;
    workflow)
      printf '%s\n' "scripts/test-monitored-workflow.sh"
      ;;
    codex-loop)
      printf '%s\n' "scripts/test-codex-loop-program.sh"
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
  local script_path=""

  script_path="$(script_for_slice "$slice")"
  printf 'verify-runtime-slice: %s\n' "$slice"
  (
    cd "$project_root"
    timeout "$timeout_secs" bash "$script_path"
  )
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
      slices=(process workflow codex-loop managed-loop)
      ;;
    process|workflow|codex-loop|managed-loop)
      slices+=("$1")
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
  shift
done

if [[ "${#slices[@]}" == "0" ]]; then
  slices=(process workflow codex-loop)
fi

parse_positive_timeout

for slice in "${slices[@]}"; do
  run_slice "$slice"
done

printf 'verify-runtime-slice: ok (%s)\n' "${slices[*]}"
