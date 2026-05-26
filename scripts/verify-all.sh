#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verify_tmp_root="${CLASP_VERIFY_TMPDIR:-${TMPDIR:-/tmp}}"
nix_config_features='experimental-features = nix-command flakes'
readonly_nix_cache_root="/tmp/clasp-nix-cache"
verify_label="${CLASP_VERIFY_LABEL:-verify-all}"
verify_lock_file="${CLASP_VERIFY_LOCK_FILE:-}"
verify_lock_owner=0
verify_lock_timeout_secs="${CLASP_VERIFY_LOCK_TIMEOUT_SECS:-0}"
verify_lock_timeout_action="${CLASP_VERIFY_ON_LOCK_TIMEOUT:-fail}"
verify_report_json="${CLASP_VERIFY_REPORT_JSON:-}"
if [[ -n "$verify_report_json" && "$verify_report_json" != /* ]]; then
  verify_report_json="$PWD/$verify_report_json"
  export CLASP_VERIFY_REPORT_JSON="$verify_report_json"
fi
verify_report_should_write=0
verify_report_finalized=0
verify_report_started_ms=0
verify_report_mode="normal"
verify_report_used_fallback=0
verify_report_used_nested=0
verify_report_output_reset=0
verify_report_first_failed_phase=""
verify_report_first_failed_group=""
verify_report_first_failed_command=""
verify_report_first_failed_exit_status=""
declare -a verify_report_commands=()
streamed_log_offset=0
verify_managed_mode="${CLASP_VERIFY_MANAGED:-auto}"
verify_managed_memory_mb="${CLASP_VERIFY_MANAGED_MEMORY_MB:-16384}"
verify_managed_min_available_memory_mb="${CLASP_VERIFY_MANAGED_MIN_AVAILABLE_MEMORY_MB:-32768}"
verify_managed_poll_secs="${CLASP_VERIFY_MANAGED_POLL_SECS:-1}"
verify_max_parallel_jobs="${CLASP_VERIFY_MAX_PARALLEL_JOBS:-1}"
if ! [[ "$verify_lock_timeout_secs" =~ ^[0-9]+$ ]]; then
  verify_lock_timeout_secs=0
fi
if ! [[ "$verify_managed_memory_mb" =~ ^[0-9]+$ ]]; then
  printf '%s: CLASP_VERIFY_MANAGED_MEMORY_MB must be a non-negative integer; got %s\n' "$verify_label" "$verify_managed_memory_mb" >&2
  exit 2
fi
if ! [[ "$verify_managed_min_available_memory_mb" =~ ^[0-9]+$ ]]; then
  printf '%s: CLASP_VERIFY_MANAGED_MIN_AVAILABLE_MEMORY_MB must be a non-negative integer; got %s\n' "$verify_label" "$verify_managed_min_available_memory_mb" >&2
  exit 2
fi
if ! [[ "$verify_managed_poll_secs" =~ ^[0-9]+$ && "$verify_managed_poll_secs" -gt 0 ]]; then
  verify_managed_poll_secs=1
fi
if ! [[ "$verify_max_parallel_jobs" =~ ^[0-9]+$ ]] || (( verify_max_parallel_jobs < 1 )); then
  verify_max_parallel_jobs=1
fi
full_parallel_verify_commands=$'
bash scripts/test-codex-loop.sh
node benchmarks/run-benchmark.mjs list >/dev/null
'
full_sequential_verify_commands=$'
bash scripts/test-selfhost.sh
bash scripts/test-source-run-cache.sh
bash scripts/test-promoted-source-export-cache.sh
bash scripts/test-int-builtins.sh
bash scripts/test-dict-builtins.sh
bash scripts/test-native-claspc.sh
bash scripts/test-record-update-parity.sh
bash scripts/test-swarm-ready-gate.sh
bash scripts/test-swarm-memory.sh
bash scripts/test-swarm-context-pack.sh
bash scripts/test-swarm-native-managed-loop.sh
bash scripts/test-swarm-native-feedback-loop.sh
bash scripts/test-monitored-loop.sh
bash scripts/test-monitored-step.sh
bash scripts/test-monitored-run-log.sh
bash scripts/test-safe-subprocess.sh
bash scripts/test-managed-job.sh
bash scripts/test-monitored-workflow.sh
bash scripts/test-codex-loop-program.sh
bash examples/agent-loop-scenario/scripts/verify.sh
bash scripts/test-agent-command-template.sh
CLASP_AGENT_COMMAND_TEMPLATE_FEEDBACK=0 CLASP_AGENT_COMMAND_TEMPLATE_NATIVE=1 bash scripts/test-agent-command-template.sh
bash scripts/test-goal-manager-agent-command-template.sh
bash scripts/test-goal-manager-default-planner-command.sh
bash scripts/test-js-process-runtime.sh
bash scripts/test-js-emitter-determinism.sh
bash examples/browser-counter/scripts/verify.sh
bash scripts/test-host-runtime.sh
bash scripts/test-safe-workspace.sh
bash scripts/test-goal-manager-child-loop-monitor.sh
bash scripts/test-feedback-loop-resume.sh
bash scripts/test-unsafe-quarantine.sh
bash scripts/test-native-runtime.sh
bash src/scripts/verify.sh
bash scripts/test-swarm-control.sh
bash examples/agent-metadata/scripts/verify.sh
bash examples/agent-task-scenario/scripts/verify.sh
bash scripts/test-verify-all.sh
bash scripts/test-verify-affected.sh
bash scripts/test-verify-compiler-slice.sh
bash scripts/test-verify-runtime-slice.sh
bash examples/lead-app-ts/scripts/verify.sh
bash benchmarks/test-benchmark-prep-cache.sh
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
bash scripts/test-verify-affected.sh
bash scripts/test-verify-compiler-slice.sh
bash scripts/test-verify-runtime-slice.sh
bash scripts/test-promoted-source-export-cache.sh
bash scripts/test-record-update-parity.sh
bash scripts/test-managed-job.sh
bash scripts/test-dict-builtins.sh
bash examples/agent-metadata/scripts/verify.sh
bash examples/agent-task-scenario/scripts/verify.sh
bash examples/agent-loop-scenario/scripts/verify.sh
bash scripts/test-task-manifest.sh
'

managed_verification_enabled() {
  case "$verify_managed_mode" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off|never|NEVER|Never)
      return 1
      ;;
  esac

  [[ "${CLASP_VERIFY_MANAGED_REENTRY:-0}" != "1" ]] || return 1
  [[ -z "${CLASP_MANAGED_JOB_ID:-}" ]] || return 1
  [[ "${CLASP_VERIFY_USE_CURRENT_SHELL:-0}" != "1" ]] || return 1
  [[ -x "$project_root/scripts/run-managed-job.sh" ]] || return 1
  return 0
}

stream_managed_log_growth() {
  local path="$1"
  local offset="$2"
  local target_fd="$3"
  local size="0"

  if [[ ! -f "$path" ]]; then
    streamed_log_offset="$offset"
    return 0
  fi

  size="$(wc -c <"$path" | tr -d '[:space:]')"
  if [[ "$size" =~ ^[0-9]+$ ]] && (( size > offset )); then
    if [[ "$target_fd" == "2" ]]; then
      tail -c +"$((offset + 1))" "$path" >&2 || true
    else
      tail -c +"$((offset + 1))" "$path" || true
    fi
    offset="$size"
  fi

  streamed_log_offset="$offset"
}

run_managed_verification() {
  local jobs_root="$project_root/.clasp-verify/jobs"
  local job_dir=""
  local stdout_offset=0
  local stderr_offset=0
  local status=""
  local exit_status=1
  local managed_args=("$project_root/scripts/run-managed-job.sh" --jobs-root "$jobs_root")

  if (( verify_managed_memory_mb > 0 )); then
    managed_args+=(--memory-mb "$verify_managed_memory_mb")
  fi
  if (( verify_managed_min_available_memory_mb > 0 )); then
    managed_args+=(--min-available-memory-mb "$verify_managed_min_available_memory_mb")
  fi

  job_dir="$(
    "${managed_args[@]}" \
      -- env \
        CLASP_VERIFY_MANAGED_REENTRY=1 \
        CLASP_NATIVE_JOBS_MAX="${CLASP_NATIVE_JOBS_MAX:-1}" \
        CLASP_NATIVE_BUNDLE_JOBS="${CLASP_NATIVE_BUNDLE_JOBS:-1}" \
        CLASP_NATIVE_IMAGE_SECTION_JOBS="${CLASP_NATIVE_IMAGE_SECTION_JOBS:-1}" \
        CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX="${CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX:-1}" \
        CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS="${CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS:-1}" \
        CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS="${CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS:-30}" \
        CLASP_VERIFY_PARALLEL_JOBS="${CLASP_VERIFY_PARALLEL_JOBS:-1}" \
        bash "$project_root/scripts/verify-all.sh"
  )"
  printf '%s: managed verification job: %s memory_mb=%s min_available_memory_mb=%s\n' \
    "$verify_label" "$job_dir" "$verify_managed_memory_mb" "$verify_managed_min_available_memory_mb" >&2

  while true; do
    stream_managed_log_growth "$job_dir/stdout.log" "$stdout_offset" 1
    stdout_offset="$streamed_log_offset"
    stream_managed_log_growth "$job_dir/stderr.log" "$stderr_offset" 2
    stderr_offset="$streamed_log_offset"
    status="$(sed -n '1p' "$job_dir/status" 2>/dev/null || printf 'missing')"
    case "$status" in
      completed|failed|stopped)
        break
        ;;
    esac
    sleep "$verify_managed_poll_secs"
  done

  stream_managed_log_growth "$job_dir/stdout.log" "$stdout_offset" 1
  stdout_offset="$streamed_log_offset"
  stream_managed_log_growth "$job_dir/stderr.log" "$stderr_offset" 2
  stderr_offset="$streamed_log_offset"

  if [[ -f "$job_dir/exit-status" ]]; then
    exit_status="$(tr -d '[:space:]' <"$job_dir/exit-status")"
  elif [[ "$status" == "completed" ]]; then
    exit_status=0
  fi
  if ! [[ "$exit_status" =~ ^[0-9]+$ ]]; then
    exit_status=1
  fi

  if [[ -f "$job_dir/memory-exceeded" ]]; then
    printf '%s: managed verification memory guard tripped:\n' "$verify_label" >&2
    sed 's/^/  /' "$job_dir/memory-exceeded" >&2 || true
  fi

  exit "$exit_status"
}

if managed_verification_enabled; then
  run_managed_verification
fi

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
nix_failure_log=""

release_verify_lock() {
  if [[ "$verify_lock_owner" != "1" ]]; then
    return 0
  fi

  rm -f "$verify_lock_dir/pid"
  rmdir "$verify_lock_dir" >/dev/null 2>&1 || true
  verify_lock_owner=0
}

verify_now_ms() {
  local now=""

  now="$(date +%s%3N 2>/dev/null || true)"
  if [[ "$now" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$now"
    return 0
  fi

  now="$(date +%s 2>/dev/null || printf '0')"
  printf '%s000\n' "$now"
}

json_escape() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

json_string() {
  printf '"%s"' "$(json_escape "$1")"
}

json_nullable_string() {
  if [[ -z "$1" ]]; then
    printf 'null'
  else
    json_string "$1"
  fi
}

verify_report_bool() {
  if [[ "$1" == "1" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

verify_report_reset_output() {
  local report_dir=""

  if [[ -z "$verify_report_json" || "$verify_report_output_reset" == "1" ]]; then
    return 0
  fi

  report_dir="$(dirname "$verify_report_json")"
  mkdir -p "$report_dir" >/dev/null 2>&1 || true
  rm -f "$verify_report_json" >/dev/null 2>&1 || true
  verify_report_output_reset=1
}

verify_report_begin() {
  local mode="$1"

  if [[ -z "$verify_report_json" ]]; then
    return 0
  fi

  verify_report_reset_output
  if [[ "$verify_report_should_write" != "1" ]]; then
    verify_report_started_ms="$(verify_now_ms)"
  fi
  verify_report_should_write=1
  verify_report_mode="$mode"

  case "$mode" in
    fallback)
      verify_report_used_fallback=1
      ;;
    nested|lock-timeout-nested)
      verify_report_used_nested=1
      ;;
  esac
}

verify_report_record_command() {
  local phase="$1"
  local group="$2"
  local command="$3"
  local exit_status="$4"
  local started_ms="$5"
  local ended_ms="$6"
  local parallel_group="${7:-}"
  local max_jobs="${8:-1}"
  local elapsed_ms=0
  local entry=""

  if [[ -z "$verify_report_json" || "$verify_report_should_write" != "1" ]]; then
    return 0
  fi

  elapsed_ms=$((ended_ms - started_ms))
  if (( elapsed_ms < 0 )); then
    elapsed_ms=0
  fi

  entry='{"phase":'
  entry+="$(json_string "$phase")"
  entry+=',"group":'
  entry+="$(json_string "$group")"
  entry+=',"parallelGroup":'
  entry+="$(json_string "$parallel_group")"
  entry+=',"maxJobs":'"$max_jobs"
  entry+=',"command":'
  entry+="$(json_string "$command")"
  entry+=',"exitStatus":'"$exit_status"
  entry+=',"startedAtMs":'"$started_ms"
  entry+=',"endedAtMs":'"$ended_ms"
  entry+=',"elapsedMs":'"$elapsed_ms"
  entry+='}'
  verify_report_commands+=("$entry")

  if (( exit_status != 0 )) && [[ -z "$verify_report_first_failed_command" ]]; then
    verify_report_first_failed_phase="$phase"
    verify_report_first_failed_group="$group"
    verify_report_first_failed_command="$command"
    verify_report_first_failed_exit_status="$exit_status"
  fi
}

verify_report_write() {
  local exit_status="$1"
  local ended_ms=0
  local elapsed_ms=0
  local verdict="failed"
  local report_dir=""
  local report_tmp=""
  local command_count=0
  local lock_held=0
  local write_status=0
  local index=0

  if [[ -z "$verify_report_json" || "$verify_report_should_write" != "1" || "$verify_report_finalized" == "1" ]]; then
    return 0
  fi

  verify_report_finalized=1
  ended_ms="$(verify_now_ms)"
  elapsed_ms=$((ended_ms - verify_report_started_ms))
  if (( elapsed_ms < 0 )); then
    elapsed_ms=0
  fi
  if (( exit_status == 0 )); then
    verdict="passed"
  fi
  if [[ "$verify_lock_owner" == "1" || "${CLASP_VERIFY_LOCK_HELD:-0}" == "1" ]]; then
    lock_held=1
  fi
  command_count="${#verify_report_commands[@]}"
  report_dir="$(dirname "$verify_report_json")"
  report_tmp="$verify_report_json.$$.$RANDOM.tmp"

  set +e
  mkdir -p "$report_dir"
  {
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "label": %s,\n' "$(json_string "$verify_label")"
    printf '  "projectRoot": %s,\n' "$(json_string "$project_root")"
    printf '  "effectiveLockFile": %s,\n' "$(json_string "$verify_lock_file")"
    printf '  "mode": %s,\n' "$(json_string "$verify_report_mode")"
    printf '  "usedFallback": %s,\n' "$(verify_report_bool "$verify_report_used_fallback")"
    printf '  "usedNested": %s,\n' "$(verify_report_bool "$verify_report_used_nested")"
    printf '  "lockHeld": %s,\n' "$(verify_report_bool "$lock_held")"
    printf '  "startedAtMs": %s,\n' "$verify_report_started_ms"
    printf '  "endedAtMs": %s,\n' "$ended_ms"
    printf '  "elapsedMs": %s,\n' "$elapsed_ms"
    printf '  "exitStatus": %s,\n' "$exit_status"
    printf '  "finalVerdict": %s,\n' "$(json_string "$verdict")"
    printf '  "firstFailedPhase": %s,\n' "$(json_nullable_string "$verify_report_first_failed_phase")"
    printf '  "firstFailedGroup": %s,\n' "$(json_nullable_string "$verify_report_first_failed_group")"
    printf '  "firstFailedCommand": %s,\n' "$(json_nullable_string "$verify_report_first_failed_command")"
    if [[ -n "$verify_report_first_failed_exit_status" ]]; then
      printf '  "firstFailedExitStatus": %s,\n' "$verify_report_first_failed_exit_status"
    else
      printf '  "firstFailedExitStatus": null,\n'
    fi
    printf '  "commandCount": %s,\n' "$command_count"
    printf '  "commands": [\n'
    for ((index = 0; index < command_count; index += 1)); do
      if (( index > 0 )); then
        printf ',\n'
      fi
      printf '    %s' "${verify_report_commands[$index]}"
    done
    printf '\n  ]\n'
    printf '}\n'
  } > "$report_tmp"
  write_status=$?
  if (( write_status == 0 )); then
    mv "$report_tmp" "$verify_report_json"
    write_status=$?
  fi
  if (( write_status != 0 )); then
    printf '%s: failed to write verification report: %s\n' "$verify_label" "$verify_report_json" >&2
    rm -f "$report_tmp"
  fi
  set -e
}

verify_all_exit_trap() {
  local exit_status=$?

  verify_report_write "$exit_status"
  if [[ -n "${nix_failure_log:-}" ]]; then
    rm -f "$nix_failure_log"
  fi
  release_verify_lock
  exit "$exit_status"
}

trap verify_all_exit_trap EXIT

acquire_verify_lock() {
  local owner_pid=""
  local waited_secs=0

  mkdir -p "$(dirname "$verify_lock_file")"

  while ! mkdir "$verify_lock_dir" >/dev/null 2>&1; do
    owner_pid="$(cat "$verify_lock_dir/pid" 2>/dev/null || true)"
    if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" >/dev/null 2>&1; then
      rm -f "$verify_lock_dir/pid"
      rmdir "$verify_lock_dir" >/dev/null 2>&1 || true
      continue
    fi
    if (( verify_lock_timeout_secs > 0 && waited_secs >= verify_lock_timeout_secs )); then
      if [[ "$verify_lock_timeout_action" == "run-nested" ]]; then
        printf '%s: verify lock busy after %ss; running nested verification\n' "$verify_label" "$waited_secs" >&2
        verify_report_begin "lock-timeout-nested"
        run_command_block "$nested_verify_commands" "nested" "nested"
        exit 0
      fi
      printf '%s: verify lock busy after %ss\n' "$verify_label" "$waited_secs" >&2
      verify_report_begin "lock-timeout"
      exit 75
    fi
    sleep 1
    waited_secs=$((waited_secs + 1))
  done

  printf '%s\n' "$$" > "$verify_lock_dir/pid"
  verify_lock_owner=1
}

if [[ -n "${NIX_CONFIG:-}" ]]; then
  export NIX_CONFIG="${NIX_CONFIG}"$'\n'"${nix_config_features}"
else
  export NIX_CONFIG="${nix_config_features}"
fi

export CLASP_NATIVE_JOBS_MAX="${CLASP_NATIVE_JOBS_MAX:-1}"
export CLASP_NATIVE_BUNDLE_JOBS="${CLASP_NATIVE_BUNDLE_JOBS:-1}"
export CLASP_NATIVE_IMAGE_SECTION_JOBS="${CLASP_NATIVE_IMAGE_SECTION_JOBS:-1}"
export CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX="${CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX:-1}"
export CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS="${CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS:-1}"
export CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS="${CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS:-30}"

mkdir -p "$verify_tmp_root"
export TMPDIR="$verify_tmp_root"

default_parallel_jobs() {
  local cpu_count=""

  cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')"
  if ! [[ "$cpu_count" =~ ^[0-9]+$ ]] || (( cpu_count < 1 )); then
    cpu_count=4
  fi
  if (( cpu_count > 1 )); then
    cpu_count=1
  fi
  printf '%s\n' "$cpu_count"
}

bounded_parallel_jobs() {
  local requested="$1"

  if ! [[ "$requested" =~ ^[0-9]+$ ]] || (( requested < 1 )); then
    requested="$(default_parallel_jobs)"
  fi
  if (( requested > verify_max_parallel_jobs )); then
    requested="$verify_max_parallel_jobs"
  fi
  printf '%s\n' "$requested"
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

run_timed_project_command() {
  local phase="$1"
  local group="$2"
  local command="$3"
  local parallel_group="${4:-}"
  local max_jobs="${5:-1}"
  local started_ms=0
  local ended_ms=0
  local exit_status=0

  if [[ -z "$verify_report_json" || "$verify_report_should_write" != "1" ]]; then
    run_project_command "$command"
    return $?
  fi

  started_ms="$(verify_now_ms)"
  set +e
  run_project_command "$command"
  exit_status=$?
  set -e
  ended_ms="$(verify_now_ms)"
  verify_report_record_command "$phase" "$group" "$command" "$exit_status" "$started_ms" "$ended_ms" "$parallel_group" "$max_jobs"
  return "$exit_status"
}

run_command_block() {
  local commands="$1"
  local phase="${2:-sequential}"
  local group="${3:-sequential}"
  local command=""
  local command_status=0

  while IFS= read -r command || [[ -n "$command" ]]; do
    [[ -z "$command" ]] && continue
    if run_timed_project_command "$phase" "$group" "$command"; then
      command_status=0
    else
      command_status=$?
    fi
    if (( command_status != 0 )); then
      printf '%s: %s command failed (exit %s): %s\n' "$verify_label" "$phase" "$command_status" "$command" >&2
      return "$command_status"
    fi
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
  declare -A pid_to_started_ms=()

  if [[ -z "$commands" ]]; then
    return 0
  fi

  if (( max_jobs <= 1 )); then
    run_command_block "$commands" "parallel" "parallel"
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
    if [[ -n "$verify_report_json" && "$verify_report_should_write" == "1" ]]; then
      pid_to_started_ms[$!]="$(verify_now_ms)"
    else
      pid_to_started_ms[$!]=0
    fi
  }

  finish_one_job() {
    local finished_command=""
    local finished_log_path=""
    local finished_pid=""
    local fallback_pid=""
    local finished_started_ms=0
    local finished_ended_ms=0
    local killed_status=0

    if wait -n -p finished_pid; then
      wait_status=0
    else
      wait_status=$?
    fi
    finished_pid="${finished_pid:-}"

    if [[ -z "$finished_pid" ]]; then
      for fallback_pid in "${!pid_to_command[@]}"; do
        finished_pid="$fallback_pid"
        break
      done
      if [[ -z "$finished_pid" ]]; then
        printf '%s: parallel wait returned without a pid and no tracked jobs remain\n' "$verify_label" >&2
        rm -rf "$temp_root"
        return 1
      fi
      set +e
      wait "$finished_pid"
      wait_status=$?
      set -e
    fi

    finished_log_path="${pid_to_log[$finished_pid]:-}"
    finished_command="${pid_to_command[$finished_pid]:-}"
    finished_started_ms="${pid_to_started_ms[$finished_pid]:-0}"
    unset 'pid_to_log[$finished_pid]'
    unset 'pid_to_command[$finished_pid]'
    unset 'pid_to_started_ms[$finished_pid]'

    if [[ -n "$verify_report_json" && "$verify_report_should_write" == "1" ]]; then
      finished_ended_ms="$(verify_now_ms)"
      verify_report_record_command "parallel" "parallel" "$finished_command" "$wait_status" "$finished_started_ms" "$finished_ended_ms" "parallel" "$max_jobs"
    fi

    if (( wait_status != 0 )); then
      printf '%s: parallel command failed (exit %s): %s\n' "$verify_label" "$wait_status" "$finished_command" >&2
      if [[ -n "$finished_log_path" && -f "$finished_log_path" ]]; then
        cat "$finished_log_path" >&2
      fi
      for finished_pid in "${!pid_to_command[@]}"; do
        kill "$finished_pid" >/dev/null 2>&1 || true
      done
      for finished_pid in "${!pid_to_command[@]}"; do
        finished_command="${pid_to_command[$finished_pid]:-}"
        finished_started_ms="${pid_to_started_ms[$finished_pid]:-0}"
        set +e
        wait "$finished_pid" >/dev/null 2>&1
        killed_status=$?
        set -e
        if [[ -n "$verify_report_json" && "$verify_report_should_write" == "1" ]]; then
          verify_report_record_command "parallel" "parallel" "$finished_command" "$killed_status" "$finished_started_ms" "$(verify_now_ms)" "parallel" "$max_jobs"
        fi
        unset 'pid_to_log[$finished_pid]'
        unset 'pid_to_command[$finished_pid]'
        unset 'pid_to_started_ms[$finished_pid]'
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

  parallel_jobs="$(bounded_parallel_jobs "$parallel_jobs")"
  run_parallel_commands "$parallel_commands" "$parallel_jobs"
  run_command_block "$sequential_commands" "sequential" "sequential"
}

fallback_commands="${CLASP_VERIFY_FALLBACK_COMMANDS-$fallback_verify_commands}"
nested_verify_commands="${CLASP_VERIFY_NESTED_COMMANDS-$fallback_commands}"

top_level_reentry=0
if [[ "${CLASP_VERIFY_TOPLEVEL_REENTRY:-0}" == "1" ]]; then
  top_level_reentry=1
  unset CLASP_VERIFY_TOPLEVEL_REENTRY
fi

if [[ "$top_level_reentry" != "1" && "${CLASP_VERIFY_IN_PROGRESS:-0}" == "1" && "${CLASP_VERIFY_ACTIVE_ROOT:-}" == "$project_root" ]]; then
  verify_report_begin "nested"
  run_command_block "$nested_verify_commands" "nested" "nested"
  exit 0
fi

if [[ -z "${XDG_CACHE_HOME:-}" || ! -w "${XDG_CACHE_HOME:-/nonexistent}" ]]; then
  export XDG_CACHE_HOME="$readonly_nix_cache_root"
  mkdir -p "$XDG_CACHE_HOME"
fi

nix_failure_log="$(mktemp)"

if [[ "${CLASP_VERIFY_LOCK_HELD:-0}" != "1" ]]; then
  acquire_verify_lock
  export CLASP_VERIFY_LOCK_HELD=1
fi

export CLASP_VERIFY_IN_PROGRESS=1
export CLASP_VERIFY_ACTIVE_ROOT="$project_root"

if [[ -n "${IN_NIX_SHELL:-}" || "${CLASP_VERIFY_USE_CURRENT_SHELL:-0}" == "1" ]]; then
  verify_report_begin "normal"
  run_verify_commands
  exit 0
fi

verify_report_reset_output
if nix develop -c bash -lc "
  set -euo pipefail
  cd \"$project_root\"
  export CLASP_PROJECT_ROOT=\"$project_root\"
  export CLASP_VERIFY_TOPLEVEL_REENTRY=1
  bash scripts/verify-all.sh
" 2>"$nix_failure_log"; then
  exit 0
fi

if grep -Eq 'readonly database|daemon-socket/socket|not tracked by Git' "$nix_failure_log"; then
  printf '%s: falling back to sandbox verification because Nix is unavailable in this environment\n' "$verify_label" >&2
  verify_report_begin "fallback"
  run_command_block "$fallback_commands" "fallback" "sequential"
  exit 0
fi

if [[ -n "$verify_report_json" && ! -s "$verify_report_json" ]]; then
  verify_report_begin "nix-failure"
fi
cat "$nix_failure_log" >&2
exit 1
