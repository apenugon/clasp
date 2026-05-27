#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "usage: $0 <task-file> [workspace] [runtime-dir]" >&2
  exit 1
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_input="$1"
workspace_input="${2:-$project_root}"
runtime_dir_input="${3:-}"
workspace="$(cd "$workspace_input" && pwd)"
task_file="$(cd "$(dirname "$task_input")" && pwd)/$(basename "$task_input")"
task_id="$(basename "$task_file" .md)"
runtime_dir="${runtime_dir_input:-$project_root/.clasp-agents/$task_id}"
runtime_dir="$(mkdir -p "$runtime_dir" && cd "$runtime_dir" && pwd)"
pid_file="$runtime_dir/loop.pid"
job_file="$runtime_dir/loop.job"
log_file="$runtime_dir/loop.log"
memory_mb="${CLASP_CODEX_LOOP_MEMORY_MB:-8192}"
min_available_memory_mb="${CLASP_CODEX_LOOP_MIN_AVAILABLE_MEMORY_MB:-40960}"

source "$project_root/scripts/clasp-swarm-common.sh"

validate_non_negative_integer() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s must be a non-negative integer; got %s\n' "$name" "$value" >&2
    exit 2
  fi
}

validate_non_negative_integer "CLASP_CODEX_LOOP_MEMORY_MB" "$memory_mb"
validate_non_negative_integer "CLASP_CODEX_LOOP_MIN_AVAILABLE_MEMORY_MB" "$min_available_memory_mb"

if [[ -f "$job_file" ]]; then
  job_dir="$(sed -n '1p' "$job_file")"
  if [[ -f "$job_dir/pid" && -f "$job_dir/status" ]]; then
    pid="$(tr -d '[:space:]' <"$job_dir/pid")"
    status="$(sed -n '1p' "$job_dir/status")"
    if [[ "$status" != "completed" && "$status" != "failed" && "$status" != "stopped" ]] &&
       kill -0 "$pid" >/dev/null 2>&1; then
      echo "codex loop already running with managed job pid $pid" >&2
      exit 1
    fi
  fi
  rm -f "$job_file" "$pid_file"
elif [[ -f "$pid_file" ]]; then
  pid="$(cat "$pid_file")"
  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "codex loop already running with unmanaged pid $pid; refusing to overwrite raw pid state" >&2
    exit 1
  fi
  rm -f "$pid_file"
fi

managed_job_args=(
  "$project_root/scripts/run-managed-job.sh"
  --jobs-root "$runtime_dir/jobs"
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
      managed-codex-loop "$log_file" \
      env \
        CLASP_NATIVE_JOBS_MAX="${CLASP_NATIVE_JOBS_MAX:-1}" \
        CLASP_NATIVE_BUNDLE_JOBS="${CLASP_NATIVE_BUNDLE_JOBS:-1}" \
        CLASP_NATIVE_IMAGE_SECTION_JOBS="${CLASP_NATIVE_IMAGE_SECTION_JOBS:-1}" \
        CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX="${CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX:-1}" \
        CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS="${CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS:-1}" \
        CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS="${CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS:-30}" \
        bash "$project_root/scripts/clasp-codex-loop.sh" "$task_file" "$workspace" "$runtime_dir"
)"
pid="$(tr -d '[:space:]' <"$job_dir/pid")"
printf '%s\n' "$job_dir" > "$job_file"
printf '%s\n' "$pid" > "$pid_file"
echo "started codex loop pid=$pid job=$job_dir log=$log_file runtime=$runtime_dir"
