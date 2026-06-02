#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/scripts/clasp-swarm-common.sh"

runtime_root="$project_root/.clasp-agents"
log_file="$runtime_root/logs/autopilot.log"
pid_file="$runtime_root/autopilot.pid"
job_file="$runtime_root/autopilot.job"
memory_mb="${CLASP_AUTOPILOT_MEMORY_MB:-8192}"
min_available_memory_mb="${CLASP_AUTOPILOT_MIN_AVAILABLE_MEMORY_MB:-45056}"
min_available_disk_mb="${CLASP_AUTOPILOT_MIN_AVAILABLE_DISK_MB:-16384}"
min_disk_headroom_mb="${CLASP_AUTOPILOT_MIN_DISK_HEADROOM_MB:-${CLASP_GENERATED_STATE_MIN_HEADROOM_MB:-1024}}"

mkdir -p "$runtime_root/logs"

validate_non_negative_integer() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s must be a non-negative integer; got %s\n' "$name" "$value" >&2
    exit 2
  fi
}

validate_non_negative_integer "CLASP_AUTOPILOT_MEMORY_MB" "$memory_mb"
validate_non_negative_integer "CLASP_AUTOPILOT_MIN_AVAILABLE_MEMORY_MB" "$min_available_memory_mb"
validate_non_negative_integer "CLASP_AUTOPILOT_MIN_AVAILABLE_DISK_MB" "$min_available_disk_mb"
validate_non_negative_integer "CLASP_AUTOPILOT_MIN_DISK_HEADROOM_MB" "$min_disk_headroom_mb"

if [[ -f "$job_file" ]]; then
  job_dir="$(sed -n '1p' "$job_file")"
  if [[ -f "$job_dir/pid" && -f "$job_dir/status" ]]; then
    pid="$(tr -d '[:space:]' <"$job_dir/pid")"
    status="$(sed -n '1p' "$job_dir/status")"
    if [[ -f "$pid_file" && "$status" != "completed" && "$status" != "failed" && "$status" != "stopped" ]] &&
       kill -0 "$pid" >/dev/null 2>&1; then
      echo "autopilot already running with managed job pid $pid" >&2
      exit 1
    fi
  fi
  rm -f "$job_file" "$pid_file"
elif [[ -f "$pid_file" ]]; then
  pid="$(cat "$pid_file")"
  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "autopilot already running with unmanaged pid $pid; refusing to overwrite raw pid state" >&2
    exit 1
  fi
  rm -f "$pid_file"
fi

managed_job_args=(
  "$project_root/scripts/run-managed-job.sh"
  --jobs-root "$runtime_root/jobs"
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
  "${managed_job_args[@]}" \
    -- bash -c '
      log_file="$1"
      pid_file="$2"
      shift 2
      cleanup() {
        rm -f "$pid_file"
      }
      trap cleanup EXIT
      "$@" >>"$log_file" 2>&1
    ' \
      managed-autopilot "$log_file" "$pid_file" \
      env \
        CLASP_NATIVE_JOBS_MAX="${CLASP_NATIVE_JOBS_MAX:-1}" \
        CLASP_NATIVE_BUNDLE_JOBS="${CLASP_NATIVE_BUNDLE_JOBS:-1}" \
        CLASP_NATIVE_IMAGE_SECTION_JOBS="${CLASP_NATIVE_IMAGE_SECTION_JOBS:-1}" \
        CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX="${CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX:-1}" \
        CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS="${CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS:-1}" \
        CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE="${CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE:-8}" \
        CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS="${CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS:-5}" \
        bash "$project_root/scripts/clasp-autopilot.sh"
)"
if clasp_swarm_wait_managed_job_immediate_terminal_status "$job_dir"; then
  clasp_swarm_print_managed_job_terminal_report "autopilot" "$job_dir"
  rm -f "$pid_file" "$job_file"
  exit 1
fi
pid="$(tr -d '[:space:]' <"$job_dir/pid")"
printf '%s\n' "$job_dir" > "$job_file"
printf '%s\n' "$pid" > "$pid_file"
echo "started autopilot pid=$pid job=$job_dir log=$log_file"
