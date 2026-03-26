#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nix_config_features='experimental-features = nix-command flakes'
readonly_nix_cache_root="/tmp/clasp-nix-cache"
verify_label="${CLASP_VERIFY_LABEL:-verify-all}"
verify_lock_file="${CLASP_VERIFY_LOCK_FILE:-}"
verify_lock_owner=0
full_parallel_verify_commands=$'
bash scripts/test-swarm-control.sh
bash scripts/test-codex-loop.sh
bash scripts/test-selfhost.sh
bash scripts/test-native-claspc.sh
bash scripts/test-native-runtime.sh
bash src/scripts/verify.sh
bash examples/lead-app-ts/scripts/verify.sh
node benchmarks/run-benchmark.mjs list >/dev/null
'
full_sequential_verify_commands=$'
bash scripts/test-verify-all.sh
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

default_parallel_jobs() {
  local cpu_count=""

  cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')"
  if ! [[ "$cpu_count" =~ ^[0-9]+$ ]] || (( cpu_count < 1 )); then
    cpu_count=4
  fi
  if (( cpu_count > 4 )); then
    cpu_count=4
  fi
  printf '%s\n' "$cpu_count"
}

run_project_command() {
  local command="$1"

  (
    set -euo pipefail
    cd "$project_root"
    export CLASP_PROJECT_ROOT="$project_root"
    bash -lc "$command"
  )
}

run_command_block() {
  local commands="$1"
  local command=""

  while IFS= read -r command || [[ -n "$command" ]]; do
    [[ -z "$command" ]] && continue
    run_project_command "$command"
  done <<< "$commands"
}

run_parallel_commands() {
  local commands="$1"
  local max_jobs="$2"
  local temp_root=""
  local next_command=""
  local finished_pid=""
  local wait_status=0
  declare -A pid_to_log=()
  declare -A pid_to_command=()

  if [[ -z "$commands" ]]; then
    return 0
  fi

  if (( max_jobs <= 1 )); then
    run_command_block "$commands"
    return 0
  fi

  temp_root="$(mktemp -d)"

  start_job() {
    local task_command="$1"
    local task_log="$temp_root/job.$$.${RANDOM}.log"

    (
      set -euo pipefail
      run_project_command "$task_command"
    ) >"$task_log" 2>&1 &

    pid_to_log[$!]="$task_log"
    pid_to_command[$!]="$task_command"
  }

  finish_one_job() {
    local finished_command=""
    local finished_log_path=""

    finished_pid=""
    if wait -n -p finished_pid; then
      wait_status=0
    else
      wait_status=$?
    fi

    finished_log_path="${pid_to_log[$finished_pid]:-}"
    finished_command="${pid_to_command[$finished_pid]:-}"
    unset 'pid_to_log[$finished_pid]'
    unset 'pid_to_command[$finished_pid]'

    if (( wait_status != 0 )); then
      printf '%s: parallel command failed: %s\n' "$verify_label" "$finished_command" >&2
      if [[ -n "$finished_log_path" && -f "$finished_log_path" ]]; then
        cat "$finished_log_path" >&2
      fi
      for finished_pid in "${!pid_to_command[@]}"; do
        kill "$finished_pid" >/dev/null 2>&1 || true
      done
      for finished_pid in "${!pid_to_command[@]}"; do
        wait "$finished_pid" >/dev/null 2>&1 || true
      done
      rm -rf "$temp_root"
      return "$wait_status"
    fi

    if [[ -n "$finished_log_path" && -s "$finished_log_path" ]]; then
      cat "$finished_log_path"
    fi
    rm -f "$finished_log_path"
    return 0
  }

  while IFS= read -r next_command || [[ -n "$next_command" ]]; do
    [[ -z "$next_command" ]] && continue
    while (( ${#pid_to_command[@]} >= max_jobs )); do
      finish_one_job || return $?
    done
    start_job "$next_command"
  done <<< "$commands"

  while (( ${#pid_to_command[@]} > 0 )); do
    finish_one_job || return $?
  done

  rm -rf "$temp_root"
}

run_verify_commands() {
  local parallel_jobs="${CLASP_VERIFY_PARALLEL_JOBS:-$(default_parallel_jobs)}"
  local parallel_commands="${CLASP_VERIFY_PARALLEL_COMMANDS-$full_parallel_verify_commands}"
  local sequential_commands="${CLASP_VERIFY_SEQUENTIAL_COMMANDS-$full_sequential_verify_commands}"

  run_parallel_commands "$parallel_commands" "$parallel_jobs"
  run_command_block "$sequential_commands"
}

fallback_commands="${CLASP_VERIFY_FALLBACK_COMMANDS-$fallback_verify_commands}"
nested_verify_commands="${CLASP_VERIFY_NESTED_COMMANDS-$fallback_commands}"

top_level_reentry=0
if [[ "${CLASP_VERIFY_TOPLEVEL_REENTRY:-0}" == "1" ]]; then
  top_level_reentry=1
  unset CLASP_VERIFY_TOPLEVEL_REENTRY
fi

if [[ "$top_level_reentry" != "1" && "${CLASP_VERIFY_IN_PROGRESS:-0}" == "1" && "${CLASP_VERIFY_ACTIVE_ROOT:-}" == "$project_root" ]]; then
  run_command_block "$nested_verify_commands"
  exit 0
fi

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

export CLASP_VERIFY_IN_PROGRESS=1
export CLASP_VERIFY_ACTIVE_ROOT="$project_root"

if [[ -n "${IN_NIX_SHELL:-}" || "${CLASP_VERIFY_USE_CURRENT_SHELL:-0}" == "1" ]]; then
  run_verify_commands
  exit 0
fi

if nix develop -c bash -lc "
  set -euo pipefail
  cd \"$project_root\"
  export CLASP_PROJECT_ROOT=\"$project_root\"
  export CLASP_VERIFY_TOPLEVEL_REENTRY=1
  bash scripts/verify-all.sh
" 2>"$nix_failure_log"; then
  exit 0
fi

if grep -Eq 'readonly database|daemon-socket/socket' "$nix_failure_log"; then
  printf '%s: falling back to sandbox verification because Nix is unavailable in this environment\n' "$verify_label" >&2
  run_command_block "$fallback_commands"
  exit 0
fi

cat "$nix_failure_log" >&2
exit 1
