#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nix_config_features='experimental-features = nix-command flakes'
readonly_nix_cache_root="/tmp/clasp-nix-cache"
verify_lock_file="${CLASP_VERIFY_LOCK_FILE:-}"
verify_lock_owner=0
full_verify_commands=$'
bash scripts/test-verify-all.sh
bash scripts/test-swarm-control.sh
cabal test
bash scripts/test-native-runtime.sh
bash compiler/hosted/scripts/verify.sh
bash examples/lead-app-ts/scripts/verify.sh
node benchmarks/run-benchmark.mjs list >/dev/null
bash benchmarks/test-task-prep.sh
bash benchmarks/test-persistence-benchmarks.sh
bash benchmarks/test-correctness-benchmarks.sh
bash benchmarks/test-external-adaptation.sh
bash benchmarks/test-foreign-interop.sh
bash benchmarks/test-interop-boundary.sh
bash benchmarks/test-secret-handling.sh
bash benchmarks/test-authorization-data-access.sh
bash benchmarks/test-audit-log.sh
bash benchmarks/test-boundary-transport-benchmarks.sh
bash benchmarks/test-backend-benchmarks.sh
bash benchmarks/test-series-summary.sh
'
fallback_verify_commands=$'
bash scripts/test-verify-all.sh
bash scripts/test-task-manifest.sh
'

default_verify_lock_file() {
  local git_common_dir=""
  local fingerprint=""

  if ! git -C "$project_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s/.clasp-verify.lock\n' "$project_root"
    return 0
  fi

  git_common_dir="$(
    git -C "$project_root" rev-parse --path-format=absolute --git-common-dir
  )"
  if [[ -w "$git_common_dir" ]]; then
    printf '%s/clasp-verify.lock\n' "$git_common_dir"
    return 0
  fi

  fingerprint="$(
    printf '%s\n' "$project_root" | cksum | awk '{print $1}'
  )"
  printf '/tmp/clasp-verify-%s.lock\n' "$fingerprint"
}

if [[ -z "$verify_lock_file" ]]; then
  verify_lock_file="$(default_verify_lock_file)"
fi
export CLASP_VERIFY_EFFECTIVE_LOCK_FILE="$verify_lock_file"

verify_lock_dir="${verify_lock_file}.d"

release_verify_lock() {
  if [[ "$verify_lock_owner" != "1" ]]; then
    return 0
  fi

  rm -f "$verify_lock_dir/pid"
  rmdir "$verify_lock_dir" >/dev/null 2>&1 || true
  verify_lock_owner=0
}

acquire_verify_lock() {
  local owner_pid=""

  mkdir -p "$(dirname "$verify_lock_file")"

  while ! mkdir "$verify_lock_dir" >/dev/null 2>&1; do
    owner_pid="$(cat "$verify_lock_dir/pid" 2>/dev/null || true)"
    if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" >/dev/null 2>&1; then
      rm -f "$verify_lock_dir/pid"
      rmdir "$verify_lock_dir" >/dev/null 2>&1 || true
      continue
    fi
    sleep 1
  done

  printf '%s\n' "$$" > "$verify_lock_dir/pid"
  verify_lock_owner=1
}

if [[ -n "${NIX_CONFIG:-}" ]]; then
  export NIX_CONFIG="${NIX_CONFIG}"$'\n'"${nix_config_features}"
else
  export NIX_CONFIG="${nix_config_features}"
fi

run_command_block() {
  local commands="$1"
  local command=""

  while IFS= read -r command; do
    [[ -z "$command" ]] && continue
    (
      set -euo pipefail
      cd "$project_root"
      export CLASP_PROJECT_ROOT="$project_root"
      bash -lc "$command"
    )
  done <<< "$commands"
}

nested_verify_commands="${CLASP_VERIFY_NESTED_COMMANDS:-${CLASP_VERIFY_FALLBACK_COMMANDS:-$fallback_verify_commands}}"

if [[ "${CLASP_VERIFY_IN_PROGRESS:-0}" == "1" && "${CLASP_VERIFY_ACTIVE_ROOT:-}" == "$project_root" ]]; then
  run_command_block "$nested_verify_commands"
  exit 0
fi

export CLASP_VERIFY_IN_PROGRESS=1
export CLASP_VERIFY_ACTIVE_ROOT="$project_root"

if [[ -z "${XDG_CACHE_HOME:-}" || ! -w "${XDG_CACHE_HOME:-/nonexistent}" ]]; then
  export XDG_CACHE_HOME="$readonly_nix_cache_root"
  mkdir -p "$XDG_CACHE_HOME"
fi

nix_failure_log="$(mktemp)"
trap 'rm -f "$nix_failure_log"; release_verify_lock' EXIT

if [[ "${CLASP_VERIFY_LOCK_HELD:-0}" != "1" ]]; then
  acquire_verify_lock
  export CLASP_VERIFY_LOCK_HELD=1
fi

if nix develop -c bash -lc "
  set -euo pipefail
  cd \"$project_root\"
  export CLASP_PROJECT_ROOT=\"$project_root\"
  ${CLASP_VERIFY_FULL_COMMANDS:-$full_verify_commands}
" 2>"$nix_failure_log"; then
  exit 0
fi

if grep -Eq 'readonly database|daemon-socket/socket' "$nix_failure_log"; then
  printf 'verify-all: falling back to sandbox verification because Nix is unavailable in this environment\n' >&2
  run_command_block "${CLASP_VERIFY_FALLBACK_COMMANDS:-$fallback_verify_commands}"
  exit 0
fi

cat "$nix_failure_log" >&2
exit 1
