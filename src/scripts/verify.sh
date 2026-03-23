#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
compiler_root="$project_root/src"
stage1_native_path="$compiler_root/stage1.native.image.json"
stage1_verify_ir_path="$compiler_root/stage1.verify.ir"
stage1_verify_native_path="$compiler_root/stage1.verify.native.image.json"
verify_root="$compiler_root/native-verify"
verify_cache_root="$compiler_root/native-verify-cache"

cleanup() {
  rm -rf "$verify_root"
  rm -rf "$verify_cache_root"
  rm -f "$stage1_verify_ir_path" "$stage1_verify_native_path"
}

trap cleanup EXIT

run_native_export() {
  if [[ -x "$project_root/runtime/target/debug/claspc" ]]; then
    CLASPC_BIN="$project_root/runtime/target/debug/claspc" \
      XDG_CACHE_HOME="$verify_cache_root/xdg" \
      bash "$project_root/src/scripts/run-native-tool.sh" "$@"
  else
    XDG_CACHE_HOME="$verify_cache_root/xdg" \
      bash "$project_root/src/scripts/run-native-tool.sh" "$@"
  fi
}

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

append_parallel_command() {
  local var_name="$1"
  shift
  local rendered=""

  printf -v rendered '%q ' "$@"
  printf -v "$var_name" '%s%s\n' "${!var_name}" "${rendered% }"
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
    while IFS= read -r command; do
      [[ -z "$command" ]] && continue
      (
        set -euo pipefail
        eval "$command"
      )
    done <<< "$commands"
    return 0
  fi

  temp_root="$(mktemp -d)"

  start_job() {
    local task_command="$1"
    local task_log="$temp_root/job.$$.${RANDOM}.log"

    (
      set -euo pipefail
      eval "$task_command"
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
      printf 'selfhost-native-verify: parallel command failed: %s\n' "$finished_command" >&2
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

assert_json_equal() {
  local left_path="$1"
  local right_path="$2"

  python - "$left_path" "$right_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as left_file:
    left_value = json.load(left_file)
with open(sys.argv[2], "r", encoding="utf-8") as right_file:
    right_value = json.load(right_file)

if left_value != right_value:
    print(f"selfhost-native-verify: JSON mismatch between {sys.argv[1]} and {sys.argv[2]}", file=sys.stderr)
    sys.exit(1)
PY
}

run_verify() {
  local parallel_jobs="${CLASP_NATIVE_VERIFY_JOBS:-$(default_parallel_jobs)}"
  local project_entry_arg="--project-entry=$project_root/src/Main.clasp"
  local rebuild_commands=""
  local export_commands=""

  cd "$project_root"
  append_parallel_command rebuild_commands run_native_export "$stage1_native_path" nativeProjectText "$project_entry_arg" "$stage1_verify_ir_path"
  append_parallel_command rebuild_commands run_native_export "$stage1_native_path" nativeImageProjectText "$project_entry_arg" "$stage1_verify_native_path"
  run_parallel_commands "$rebuild_commands" "$parallel_jobs"
  assert_json_equal "$stage1_native_path" "$stage1_verify_native_path"
  mkdir -p "$verify_root"

  append_parallel_command export_commands run_native_export "$stage1_native_path" main "$verify_root/promoted.snapshot.json"
  append_parallel_command export_commands run_native_export "$stage1_verify_native_path" main "$verify_root/rebuilt.snapshot.json"
  append_parallel_command export_commands run_native_export "$stage1_native_path" checkEntrypoint "$verify_root/promoted.check.txt"
  append_parallel_command export_commands run_native_export "$stage1_verify_native_path" checkEntrypoint "$verify_root/rebuilt.check.txt"
  append_parallel_command export_commands run_native_export "$stage1_native_path" explainEntrypoint "$verify_root/promoted.explain.txt"
  append_parallel_command export_commands run_native_export "$stage1_verify_native_path" explainEntrypoint "$verify_root/rebuilt.explain.txt"
  append_parallel_command export_commands run_native_export "$stage1_native_path" compileEntrypoint "$verify_root/promoted.compile.mjs"
  append_parallel_command export_commands run_native_export "$stage1_verify_native_path" compileEntrypoint "$verify_root/rebuilt.compile.mjs"
  append_parallel_command export_commands run_native_export "$stage1_native_path" nativeEntrypoint "$verify_root/promoted.native.ir"
  append_parallel_command export_commands run_native_export "$stage1_verify_native_path" nativeEntrypoint "$verify_root/rebuilt.native.ir"
  append_parallel_command export_commands run_native_export "$stage1_native_path" nativeImageEntrypoint "$verify_root/promoted.native.image.json"
  append_parallel_command export_commands run_native_export "$stage1_verify_native_path" nativeImageEntrypoint "$verify_root/rebuilt.native.image.json"
  append_parallel_command export_commands run_native_export "$stage1_native_path" checkProjectText "$project_entry_arg" "$verify_root/promoted.source.check.txt"
  append_parallel_command export_commands run_native_export "$stage1_verify_native_path" checkProjectText "$project_entry_arg" "$verify_root/rebuilt.source.check.txt"
  append_parallel_command export_commands run_native_export "$stage1_native_path" checkCoreProjectText "$project_entry_arg" "$verify_root/promoted.source.check-core.json"
  append_parallel_command export_commands run_native_export "$stage1_verify_native_path" checkCoreProjectText "$project_entry_arg" "$verify_root/rebuilt.source.check-core.json"
  append_parallel_command export_commands run_native_export "$stage1_native_path" compileProjectText "$project_entry_arg" "$verify_root/promoted.source.compile.mjs"
  append_parallel_command export_commands run_native_export "$stage1_verify_native_path" compileProjectText "$project_entry_arg" "$verify_root/rebuilt.source.compile.mjs"
  append_parallel_command export_commands run_native_export "$stage1_native_path" nativeProjectText "$project_entry_arg" "$verify_root/promoted.source.native.ir"
  append_parallel_command export_commands run_native_export "$stage1_verify_native_path" nativeProjectText "$project_entry_arg" "$verify_root/rebuilt.source.native.ir"
  append_parallel_command export_commands run_native_export "$stage1_native_path" nativeImageProjectText "$project_entry_arg" "$verify_root/promoted.source.native.image.json"
  append_parallel_command export_commands run_native_export "$stage1_verify_native_path" nativeImageProjectText "$project_entry_arg" "$verify_root/rebuilt.source.native.image.json"
  run_parallel_commands "$export_commands" "$parallel_jobs"

  cmp -s "$verify_root/promoted.snapshot.json" "$verify_root/rebuilt.snapshot.json"
  cmp -s "$verify_root/promoted.check.txt" "$verify_root/rebuilt.check.txt"
  cmp -s "$verify_root/promoted.explain.txt" "$verify_root/rebuilt.explain.txt"
  cmp -s "$verify_root/promoted.compile.mjs" "$verify_root/rebuilt.compile.mjs"
  cmp -s "$verify_root/promoted.native.ir" "$verify_root/rebuilt.native.ir"
  assert_json_equal "$verify_root/promoted.native.image.json" "$verify_root/rebuilt.native.image.json"
  cmp -s "$verify_root/promoted.source.check.txt" "$verify_root/rebuilt.source.check.txt"
  cmp -s "$verify_root/promoted.source.check-core.json" "$verify_root/rebuilt.source.check-core.json"
  cmp -s "$verify_root/promoted.source.compile.mjs" "$verify_root/rebuilt.source.compile.mjs"
  cmp -s "$verify_root/promoted.source.native.ir" "$verify_root/rebuilt.source.native.ir"
  assert_json_equal "$verify_root/promoted.source.native.image.json" "$verify_root/rebuilt.source.native.image.json"

  printf '%s\n' '{"nativeSeedMatchesPromoted":true,"nativeCheckMatchesPromoted":true,"nativeExplainMatchesPromoted":true,"nativeCompileMatchesPromoted":true,"nativeIrMatchesPromoted":true,"nativeImageMatchesPromoted":true,"nativeSourceCheckMatchesPromoted":true,"nativeSourceCheckCoreMatchesPromoted":true,"nativeSourceCompileMatchesPromoted":true,"nativeSourceIrMatchesPromoted":true,"nativeSourceImageMatchesPromoted":true}'
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  run_verify | tail -n 1 | grep -F '"nativeSeedMatchesPromoted":true,"nativeCheckMatchesPromoted":true,"nativeExplainMatchesPromoted":true,"nativeCompileMatchesPromoted":true,"nativeIrMatchesPromoted":true,"nativeImageMatchesPromoted":true,"nativeSourceCheckMatchesPromoted":true,"nativeSourceCheckCoreMatchesPromoted":true,"nativeSourceCompileMatchesPromoted":true,"nativeSourceIrMatchesPromoted":true,"nativeSourceImageMatchesPromoted":true'
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash src/scripts/verify.sh
  "
fi
