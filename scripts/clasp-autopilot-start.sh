#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_root="$project_root/.clasp-agents"
log_file="$runtime_root/logs/autopilot.log"
pid_file="$runtime_root/autopilot.pid"
job_file="$runtime_root/autopilot.job"
memory_mb="${CLASP_AUTOPILOT_MEMORY_MB:-12288}"
min_available_memory_mb="${CLASP_AUTOPILOT_MIN_AVAILABLE_MEMORY_MB:-24576}"

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

if [[ -f "$job_file" ]]; then
  job_dir="$(sed -n '1p' "$job_file")"
  if [[ -f "$job_dir/pid" && -f "$job_dir/status" ]]; then
    pid="$(tr -d '[:space:]' <"$job_dir/pid")"
    status="$(sed -n '1p' "$job_dir/status")"
    if [[ "$status" != "completed" && "$status" != "failed" && "$status" != "stopped" ]] &&
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

job_dir="$(
  "${managed_job_args[@]}" \
    -- bash -c 'log_file="$1"; shift; exec "$@" >>"$log_file" 2>&1' \
      managed-autopilot "$log_file" \
      bash "$project_root/scripts/clasp-autopilot.sh"
)"
pid="$(tr -d '[:space:]' <"$job_dir/pid")"
printf '%s\n' "$job_dir" > "$job_file"
printf '%s\n' "$pid" > "$pid_file"
echo "started autopilot pid=$pid job=$job_dir log=$log_file"
