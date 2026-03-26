#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
compiler_root="$project_root/src"
embedded_native_path="$compiler_root/embedded.native.image.json"
embedded_compiler_native_path="$compiler_root/embedded.compiler.native.image.json"
embedded_verify_ir_path="$compiler_root/embedded.verify.ir"
embedded_verify_native_path="$compiler_root/embedded.verify.native.image.json"
verify_root="$compiler_root/native-verify"
verify_cache_root="$compiler_root/native-verify-cache"
reset_verify_cache="${CLASP_NATIVE_VERIFY_RESET_CACHE:-0}"
verify_mode="${CLASP_NATIVE_VERIFY_MODE:-fast}"
fast_verify_source_path="${CLASP_NATIVE_VERIFY_SOURCE_INPUT:-$project_root/examples/feedback-loop/Main.clasp}"
verify_lock_file="${CLASP_NATIVE_VERIFY_LOCK_FILE:-$compiler_root/.native-verify.lock}"
verify_lock_dir="${verify_lock_file}.d"
verify_lock_owner=0

cleanup() {
  rm -rf "$verify_root"
  if [[ "$reset_verify_cache" == "1" ]]; then
    rm -rf "$verify_cache_root"
  fi
  rm -f "$embedded_verify_ir_path" "$embedded_verify_native_path"
  release_verify_lock
}

trap cleanup EXIT

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

run_native_export() {
  CLASPC_BIN="$(resolve_native_claspc_bin)" \
    XDG_CACHE_HOME="$verify_cache_root/xdg" \
    bash "$project_root/src/scripts/run-native-tool.sh" "$@"
}

resolve_native_claspc_bin() {
  if [[ -n "${CLASPC_BIN:-}" ]]; then
    printf '%s\n' "$CLASPC_BIN"
  elif [[ -x "$project_root/runtime/target/debug/claspc" ]]; then
    printf '%s\n' "$project_root/runtime/target/debug/claspc"
  else
    "$project_root/scripts/resolve-claspc.sh"
  fi
}

run_native_check() {
  local input_path="$1"
  local output_path="$2"
  local claspc_bin=""

  claspc_bin="$(resolve_native_claspc_bin)"
  XDG_CACHE_HOME="$verify_cache_root/xdg" \
    "$claspc_bin" --json check "$input_path" >"$output_path"
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

  node - "$left_path" "$right_path" <<'JS'
const fs = require("node:fs");

const renames = {
  stage2CompilerModule: "candidateCompilerModule",
  compilerSnapshotStage2Module: "compilerSnapshotCandidateModule",
  stage2EmittedModule: "candidateEmittedModule",
  stage2CheckOutput: "candidateCheckOutput",
  stage2ExplainOutput: "candidateExplainOutput",
  stage2NativeOutput: "candidateNativeOutput",
};

function normalize(value) {
  if (Array.isArray(value)) {
    return value.map(normalize);
  }
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [renames[key] || key, normalize(item)]),
    );
  }
  if (typeof value === "string") {
    let text = value;
    for (const [left, right] of Object.entries(renames)) {
      text = text.split(left).join(right);
    }
    return text;
  }
  return value;
}

const leftPath = process.argv[2];
const rightPath = process.argv[3];
const leftValue = normalize(JSON.parse(fs.readFileSync(leftPath, "utf8")));
const rightValue = normalize(JSON.parse(fs.readFileSync(rightPath, "utf8")));

if (JSON.stringify(leftValue) !== JSON.stringify(rightValue)) {
  console.error(`selfhost-native-verify: JSON mismatch between ${leftPath} and ${rightPath}`);
  process.exit(1);
}
JS
}

run_verify() {
  local parallel_jobs="${CLASP_NATIVE_VERIFY_JOBS:-$(default_parallel_jobs)}"
  local project_entry_arg="--project-entry=$project_root/src/Main.clasp"
  local rebuild_commands=""
  local export_commands=""
  local verify_summary=""

  case "$verify_mode" in
    fast|full)
      ;;
    *)
      printf 'selfhost-native-verify: unsupported mode: %s\n' "$verify_mode" >&2
      return 1
      ;;
  esac

  cd "$project_root"
  if [[ "$verify_mode" == "full" ]]; then
    append_parallel_command rebuild_commands run_native_export "$embedded_compiler_native_path" nativeProjectText "$project_entry_arg" "$embedded_verify_ir_path"
    append_parallel_command rebuild_commands run_native_export "$embedded_compiler_native_path" nativeImageProjectText "$project_entry_arg" "$embedded_verify_native_path"
  fi
  run_parallel_commands "$rebuild_commands" "$parallel_jobs"
  mkdir -p "$verify_root"

  if [[ "$verify_mode" == "full" ]]; then
    assert_json_equal "$embedded_native_path" "$embedded_verify_native_path"
    append_parallel_command export_commands run_native_export "$embedded_native_path" main "$verify_root/promoted.snapshot.json"
    append_parallel_command export_commands run_native_export "$embedded_verify_native_path" main "$verify_root/rebuilt.snapshot.json"
    append_parallel_command export_commands run_native_export "$embedded_native_path" checkEntrypoint "$verify_root/promoted.check.txt"
    append_parallel_command export_commands run_native_export "$embedded_verify_native_path" checkEntrypoint "$verify_root/rebuilt.check.txt"
    append_parallel_command export_commands run_native_export "$embedded_native_path" explainEntrypoint "$verify_root/promoted.explain.txt"
    append_parallel_command export_commands run_native_export "$embedded_verify_native_path" explainEntrypoint "$verify_root/rebuilt.explain.txt"
    append_parallel_command export_commands run_native_export "$embedded_native_path" compileEntrypoint "$verify_root/promoted.compile.mjs"
    append_parallel_command export_commands run_native_export "$embedded_verify_native_path" compileEntrypoint "$verify_root/rebuilt.compile.mjs"
    append_parallel_command export_commands run_native_export "$embedded_native_path" nativeEntrypoint "$verify_root/promoted.native.ir"
    append_parallel_command export_commands run_native_export "$embedded_verify_native_path" nativeEntrypoint "$verify_root/rebuilt.native.ir"
    append_parallel_command export_commands run_native_export "$embedded_native_path" nativeImageEntrypoint "$verify_root/promoted.native.image.json"
    append_parallel_command export_commands run_native_export "$embedded_verify_native_path" nativeImageEntrypoint "$verify_root/rebuilt.native.image.json"
    append_parallel_command export_commands run_native_export "$embedded_compiler_native_path" checkProjectText "$project_entry_arg" "$verify_root/promoted.source.check.txt"
    append_parallel_command export_commands run_native_export "$embedded_verify_native_path" checkProjectText "$project_entry_arg" "$verify_root/rebuilt.source.check.txt"
    append_parallel_command export_commands run_native_export "$embedded_compiler_native_path" checkCoreProjectText "$project_entry_arg" "$verify_root/promoted.source.check-core.json"
    append_parallel_command export_commands run_native_export "$embedded_verify_native_path" checkCoreProjectText "$project_entry_arg" "$verify_root/rebuilt.source.check-core.json"
    append_parallel_command export_commands run_native_export "$embedded_compiler_native_path" compileProjectText "$project_entry_arg" "$verify_root/promoted.source.compile.mjs"
    append_parallel_command export_commands run_native_export "$embedded_verify_native_path" compileProjectText "$project_entry_arg" "$verify_root/rebuilt.source.compile.mjs"
    append_parallel_command export_commands run_native_export "$embedded_compiler_native_path" nativeProjectText "$project_entry_arg" "$verify_root/promoted.source.native.ir"
    append_parallel_command export_commands run_native_export "$embedded_verify_native_path" nativeProjectText "$project_entry_arg" "$verify_root/rebuilt.source.native.ir"
    append_parallel_command export_commands run_native_export "$embedded_compiler_native_path" nativeImageProjectText "$project_entry_arg" "$verify_root/promoted.source.native.image.json"
    append_parallel_command export_commands run_native_export "$embedded_verify_native_path" nativeImageProjectText "$project_entry_arg" "$verify_root/rebuilt.source.native.image.json"
  else
    append_parallel_command export_commands run_native_export "$embedded_native_path" main "$verify_root/promoted.snapshot.json"
    append_parallel_command export_commands run_native_check "$fast_verify_source_path" "$verify_root/promoted.source.check.json"
  fi

  run_parallel_commands "$export_commands" "$parallel_jobs"

  if [[ "$verify_mode" == "full" ]]; then
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
    verify_summary='{"mode":"full","nativeSeedMatchesPromoted":true,"nativeCheckMatchesPromoted":true,"nativeExplainMatchesPromoted":true,"nativeCompileMatchesPromoted":true,"nativeIrMatchesPromoted":true,"nativeImageMatchesPromoted":true,"nativeSourceCheckMatchesPromoted":true,"nativeSourceCheckCoreMatchesPromoted":true,"nativeSourceCompileMatchesPromoted":true,"nativeSourceIrMatchesPromoted":true,"nativeSourceImageMatchesPromoted":true}'
  else
    test -s "$verify_root/promoted.snapshot.json"
    grep -F '"status":"ok","command":"check"' "$verify_root/promoted.source.check.json" >/dev/null
    verify_summary='{"mode":"fast","promotedSnapshotExecutes":true,"promotedSourceCheckExecutes":true}'
  fi

  printf '%s\n' "$verify_summary"
}

if [[ "${CLASP_NATIVE_VERIFY_LOCK_HELD:-0}" != "1" ]]; then
  acquire_verify_lock
  export CLASP_NATIVE_VERIFY_LOCK_HELD=1
fi

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  if [[ "$verify_mode" == "full" ]]; then
    run_verify | tail -n 1 | grep -F '"mode":"full","nativeSeedMatchesPromoted":true,"nativeCheckMatchesPromoted":true,"nativeExplainMatchesPromoted":true,"nativeCompileMatchesPromoted":true,"nativeIrMatchesPromoted":true,"nativeImageMatchesPromoted":true,"nativeSourceCheckMatchesPromoted":true,"nativeSourceCheckCoreMatchesPromoted":true,"nativeSourceCompileMatchesPromoted":true,"nativeSourceIrMatchesPromoted":true,"nativeSourceImageMatchesPromoted":true'
  else
    run_verify | tail -n 1 | grep -F '"mode":"fast","promotedSnapshotExecutes":true,"promotedSourceCheckExecutes":true'
  fi
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    export CLASP_NATIVE_VERIFY_MODE=\"$verify_mode\"
    export CLASP_NATIVE_VERIFY_LOCK_FILE=\"$verify_lock_file\"
    export CLASP_NATIVE_VERIFY_LOCK_HELD=\"${CLASP_NATIVE_VERIFY_LOCK_HELD:-0}\"
    bash src/scripts/verify.sh
  "
fi
