#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/scripts/clasp-swarm-common.sh"

usage() {
  cat <<'EOF' >&2
usage: scripts/clasp-swarm-supervise.sh [options] [wave-name]

Starts examples/swarm-native/SwarmSupervisor.clasp as a managed resident job.
The supervisor loop stays in Clasp; this launcher only provides safe managed-job
admission, duplicate-run detection, and stable state/job paths.

Options:
  --profile, --launch-profile <name>       Swarm launch profile used by the supervisor.
  --state-root <dir>                       Supervisor state directory.
  --jobs-root <dir>                        Managed job directory for the supervisor.
  --max-iterations <n>                     Supervisor iteration limit.
  --poll-ms <n>                            Poll delay in milliseconds.
  --command-timeout-ms <n>                 Per-command timeout in milliseconds.
  --report-event-limit <n>                 Retained event count in report JSON.
  --dry-run                                Ask the Clasp supervisor to report starts only.
  --no-fallback                            Disable lower-memory fallback launch attempts.
  --help                                   Show this help.
EOF
}

json_string() {
  printf '"%s"\n' "$1"
}

validate_non_negative_integer() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s must be a non-negative integer; got %s\n' "$name" "$value" >&2
    exit 2
  fi
}

validate_launch_profile() {
  case "$1" in
    ""|default|bounded-low-memory|bounded-memory-pressure)
      ;;
    *)
      printf 'clasp-swarm-supervise: unknown launch profile: %s\n' "$1" >&2
      exit 2
      ;;
  esac
}

managed_supervisor_is_running() {
  local job_dir="$1"
  local status=""
  local pid=""

  [[ -d "$job_dir" && -f "$job_dir/status" && -f "$job_dir/pid" ]] || return 1
  status="$(clasp_swarm_managed_job_status "$job_dir")"
  clasp_swarm_managed_job_status_is_terminal "$status" && return 1
  pid="$(tr -d '[:space:]' <"$job_dir/pid")"
  [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1
}

wave_name=""
launch_profile="${CLASP_SWARM_SUPERVISOR_PROFILE:-${CLASP_SWARM_PROFILE:-bounded-memory-pressure}}"
state_root_arg=""
jobs_root="${CLASP_SWARM_SUPERVISOR_JOBS_ROOT:-$project_root/.clasp-swarm/supervisor-jobs}"
max_iterations="${CLASP_SWARM_SUPERVISOR_MAX_ITERATIONS:-240}"
poll_ms="${CLASP_SWARM_SUPERVISOR_POLL_MS:-30000}"
command_timeout_ms="${CLASP_SWARM_SUPERVISOR_COMMAND_TIMEOUT_MS:-120000}"
report_event_limit="${CLASP_SWARM_SUPERVISOR_REPORT_EVENT_LIMIT:-200}"
dry_run="${CLASP_SWARM_SUPERVISOR_DRY_RUN:-false}"
allow_fallback="${CLASP_SWARM_SUPERVISOR_ALLOW_FALLBACK:-true}"
memory_mb="${CLASP_SWARM_SUPERVISOR_MEMORY_MB:-4096}"
min_available_memory_mb="${CLASP_SWARM_SUPERVISOR_MIN_AVAILABLE_MEMORY_MB:-16384}"
min_available_disk_mb="${CLASP_SWARM_SUPERVISOR_MIN_AVAILABLE_DISK_MB:-${CLASP_SWARM_MIN_AVAILABLE_DISK_MB:-16384}}"
min_disk_headroom_mb="${CLASP_SWARM_SUPERVISOR_MIN_DISK_HEADROOM_MB:-${CLASP_SWARM_MIN_DISK_HEADROOM_MB:-${CLASP_GENERATED_STATE_MIN_HEADROOM_MB:-1024}}}"
external_agent_reserve_mb="${CLASP_SWARM_SUPERVISOR_EXTERNAL_AGENT_RESERVE_MB:-${CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB:-512}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --profile|--launch-profile)
      if [[ $# -lt 2 ]]; then
        printf 'clasp-swarm-supervise: %s requires a value\n' "$1" >&2
        exit 2
      fi
      launch_profile="$2"
      shift 2
      ;;
    --profile=*|--launch-profile=*)
      launch_profile="${1#*=}"
      shift
      ;;
    --state-root)
      if [[ $# -lt 2 ]]; then
        printf 'clasp-swarm-supervise: --state-root requires a value\n' >&2
        exit 2
      fi
      state_root_arg="$2"
      shift 2
      ;;
    --state-root=*)
      state_root_arg="${1#*=}"
      shift
      ;;
    --jobs-root)
      if [[ $# -lt 2 ]]; then
        printf 'clasp-swarm-supervise: --jobs-root requires a value\n' >&2
        exit 2
      fi
      jobs_root="$2"
      shift 2
      ;;
    --jobs-root=*)
      jobs_root="${1#*=}"
      shift
      ;;
    --max-iterations)
      if [[ $# -lt 2 ]]; then
        printf 'clasp-swarm-supervise: --max-iterations requires a value\n' >&2
        exit 2
      fi
      max_iterations="$2"
      shift 2
      ;;
    --max-iterations=*)
      max_iterations="${1#*=}"
      shift
      ;;
    --poll-ms)
      if [[ $# -lt 2 ]]; then
        printf 'clasp-swarm-supervise: --poll-ms requires a value\n' >&2
        exit 2
      fi
      poll_ms="$2"
      shift 2
      ;;
    --poll-ms=*)
      poll_ms="${1#*=}"
      shift
      ;;
    --command-timeout-ms)
      if [[ $# -lt 2 ]]; then
        printf 'clasp-swarm-supervise: --command-timeout-ms requires a value\n' >&2
        exit 2
      fi
      command_timeout_ms="$2"
      shift 2
      ;;
    --command-timeout-ms=*)
      command_timeout_ms="${1#*=}"
      shift
      ;;
    --report-event-limit)
      if [[ $# -lt 2 ]]; then
        printf 'clasp-swarm-supervise: --report-event-limit requires a value\n' >&2
        exit 2
      fi
      report_event_limit="$2"
      shift 2
      ;;
    --report-event-limit=*)
      report_event_limit="${1#*=}"
      shift
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --no-fallback)
      allow_fallback=false
      shift
      ;;
    --*)
      usage
      exit 2
      ;;
    *)
      if [[ -n "$wave_name" ]]; then
        usage
        exit 2
      fi
      wave_name="$1"
      shift
      ;;
  esac
done

wave_name="${wave_name:-$(clasp_swarm_default_wave)}"
state_root="${state_root_arg:-$project_root/.clasp-swarm/supervisor/$wave_name}"

validate_launch_profile "$launch_profile"
validate_non_negative_integer "CLASP_SWARM_SUPERVISOR_MAX_ITERATIONS" "$max_iterations"
validate_non_negative_integer "CLASP_SWARM_SUPERVISOR_POLL_MS" "$poll_ms"
validate_non_negative_integer "CLASP_SWARM_SUPERVISOR_COMMAND_TIMEOUT_MS" "$command_timeout_ms"
validate_non_negative_integer "CLASP_SWARM_SUPERVISOR_REPORT_EVENT_LIMIT" "$report_event_limit"
validate_non_negative_integer "CLASP_SWARM_SUPERVISOR_MEMORY_MB" "$memory_mb"
validate_non_negative_integer "CLASP_SWARM_SUPERVISOR_MIN_AVAILABLE_MEMORY_MB" "$min_available_memory_mb"
validate_non_negative_integer "CLASP_SWARM_SUPERVISOR_MIN_AVAILABLE_DISK_MB" "$min_available_disk_mb"
validate_non_negative_integer "CLASP_SWARM_SUPERVISOR_MIN_DISK_HEADROOM_MB" "$min_disk_headroom_mb"
validate_non_negative_integer "CLASP_SWARM_SUPERVISOR_EXTERNAL_AGENT_RESERVE_MB" "$external_agent_reserve_mb"

mkdir -p "$state_root" "$jobs_root"
state_root="$(cd "$state_root" && pwd -P)"
jobs_root="$(cd "$jobs_root" && pwd -P)"
job_file="$state_root/job"

if [[ -f "$job_file" ]]; then
  job_dir="$(sed -n '1p' "$job_file")"
  if managed_supervisor_is_running "$job_dir"; then
    pid="$(tr -d '[:space:]' <"$job_dir/pid")"
    printf 'supervisor already running pid=%s job=%s state=%s\n' "$pid" "$job_dir" "$state_root" >&2
    printf 'supervisor_status=already-running\n'
    printf 'supervisor_job=%s\n' "$job_dir"
    printf 'supervisor_pid=%s\n' "$pid"
    printf 'supervisor_state=%s\n' "$state_root"
    exit 0
  fi
fi

claspc_bin="${CLASP_SWARM_SUPERVISOR_CLASPC_BIN:-$("$project_root/scripts/resolve-claspc.sh")}"
workspace_json="${CLASP_SWARM_SUPERVISOR_WORKSPACE_JSON:-$(json_string "$project_root")}"
wave_json="${CLASP_SWARM_SUPERVISOR_WAVE_JSON:-$(json_string "$wave_name")}"
profile_json="${CLASP_SWARM_SUPERVISOR_PROFILE_JSON:-$(json_string "$launch_profile")}"
max_iterations_json="${CLASP_SWARM_SUPERVISOR_MAX_ITERATIONS_JSON:-$max_iterations}"
poll_ms_json="${CLASP_SWARM_SUPERVISOR_POLL_MS_JSON:-$poll_ms}"
command_timeout_ms_json="${CLASP_SWARM_SUPERVISOR_COMMAND_TIMEOUT_MS_JSON:-$command_timeout_ms}"
report_event_limit_json="${CLASP_SWARM_SUPERVISOR_REPORT_EVENT_LIMIT_JSON:-$report_event_limit}"
dry_run_json="${CLASP_SWARM_SUPERVISOR_DRY_RUN_JSON:-$dry_run}"
allow_fallback_json="${CLASP_SWARM_SUPERVISOR_ALLOW_FALLBACK_JSON:-$allow_fallback}"

managed_job_args=(
  "$project_root/scripts/run-managed-job.sh"
  --jobs-root "$jobs_root"
)
if (( memory_mb > 0 )); then
  managed_job_args+=(--memory-mb "$memory_mb")
fi
if (( min_available_memory_mb > 0 )); then
  managed_job_args+=(--min-available-memory-mb "$min_available_memory_mb")
fi
if (( min_available_disk_mb > 0 )); then
  managed_job_args+=(--min-available-disk-mb "$min_available_disk_mb" --disk-reserve-path "$project_root")
fi
if (( min_disk_headroom_mb > 0 )); then
  managed_job_args+=(--min-disk-headroom-mb "$min_disk_headroom_mb" --disk-reserve-path "$project_root")
fi

job_dir="$(
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB="$external_agent_reserve_mb" \
    "${managed_job_args[@]}" \
    -- env \
      CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB="$external_agent_reserve_mb" \
      CLASP_SWARM_SUPERVISOR_WORKSPACE_JSON="$workspace_json" \
      CLASP_SWARM_SUPERVISOR_WAVE_JSON="$wave_json" \
      CLASP_SWARM_SUPERVISOR_PROFILE_JSON="$profile_json" \
      CLASP_SWARM_SUPERVISOR_MAX_ITERATIONS_JSON="$max_iterations_json" \
      CLASP_SWARM_SUPERVISOR_POLL_MS_JSON="$poll_ms_json" \
      CLASP_SWARM_SUPERVISOR_COMMAND_TIMEOUT_MS_JSON="$command_timeout_ms_json" \
      CLASP_SWARM_SUPERVISOR_REPORT_EVENT_LIMIT_JSON="$report_event_limit_json" \
      CLASP_SWARM_SUPERVISOR_DRY_RUN_JSON="$dry_run_json" \
      CLASP_SWARM_SUPERVISOR_ALLOW_FALLBACK_JSON="$allow_fallback_json" \
      CLASP_NATIVE_JOBS_MAX="${CLASP_NATIVE_JOBS_MAX:-1}" \
      CLASP_NATIVE_BUNDLE_JOBS="${CLASP_NATIVE_BUNDLE_JOBS:-1}" \
      CLASP_NATIVE_IMAGE_SECTION_JOBS="${CLASP_NATIVE_IMAGE_SECTION_JOBS:-1}" \
      CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX="${CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX:-1}" \
      CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS="${CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS:-1}" \
      CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE="${CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE:-8}" \
      CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS="${CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS:-5}" \
      "$claspc_bin" run "$project_root/examples/swarm-native/SwarmSupervisor.clasp" -- "$state_root"
)"

if clasp_swarm_wait_managed_job_immediate_terminal_status "$job_dir"; then
  clasp_swarm_print_managed_job_terminal_report "swarm supervisor" "$job_dir"
  exit 1
fi

printf '%s\n' "$job_dir" >"$job_file"
pid="$(tr -d '[:space:]' <"$job_dir/pid")"
printf 'supervisor_status=started\n'
printf 'supervisor_job=%s\n' "$job_dir"
printf 'supervisor_pid=%s\n' "$pid"
printf 'supervisor_state=%s\n' "$state_root"
