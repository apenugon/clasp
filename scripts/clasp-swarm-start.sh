#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/scripts/clasp-swarm-common.sh"

wave_name="${1:-$(clasp_swarm_default_wave)}"
trunk_branch="${CLASP_SWARM_TRUNK_BRANCH:-agents/swarm-trunk}"
main_branch="${CLASP_SWARM_MAIN_BRANCH:-main}"
source_ref="${CLASP_SWARM_SOURCE_REF:-HEAD}"
allow_dirty="${CLASP_SWARM_ALLOW_DIRTY:-0}"
batch_filter="${CLASP_SWARM_BATCH:-}"
max_running_lanes="${CLASP_SWARM_MAX_RUNNING_LANES:-1}"
lane_memory_mb="${CLASP_SWARM_LANE_MEMORY_MB:-8192}"
min_available_memory_mb="${CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB:-40960}"
native_jobs_max="${CLASP_SWARM_NATIVE_JOBS_MAX:-1}"
native_bundle_jobs="${CLASP_SWARM_NATIVE_BUNDLE_JOBS:-1}"
native_image_section_jobs="${CLASP_SWARM_NATIVE_IMAGE_SECTION_JOBS:-1}"
native_image_section_jobs_max="${CLASP_SWARM_NATIVE_IMAGE_SECTION_JOBS_MAX:-1}"
native_image_module_decl_fresh_process="${CLASP_SWARM_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS:-1}"
native_export_host_idle_timeout_secs="${CLASP_SWARM_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS:-30}"

validate_non_negative_integer() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s must be a non-negative integer; got %s\n' "$name" "$value" >&2
    exit 2
  fi
}

available_memory_mb() {
  awk '/MemAvailable:/ { printf "%d\n", int($2 / 1024); found = 1 } END { if (!found) print 0 }' /proc/meminfo 2>/dev/null || printf '0\n'
}

lane_runtime_is_running() {
  local runtime_root="$1"
  local job_file="$runtime_root/job"
  local pid_file="$runtime_root/pid"
  local job_dir=""
  local pid=""
  local status=""

  if [[ -f "$job_file" ]]; then
    job_dir="$(sed -n '1p' "$job_file")"
    if [[ -f "$job_dir/pid" && -f "$job_dir/status" ]]; then
      pid="$(tr -d '[:space:]' <"$job_dir/pid")"
      status="$(sed -n '1p' "$job_dir/status")"
      if [[ "$status" != "completed" && "$status" != "failed" && "$status" != "stopped" ]] &&
         kill -0 "$pid" >/dev/null 2>&1; then
        return 0
      fi
    fi
  elif [[ -f "$pid_file" ]]; then
    pid="$(tr -d '[:space:]' <"$pid_file")"
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

running_lane_count_for_wave() {
  local count=0
  local lane_dir=""
  local lane_name=""
  local runtime_root=""

  while IFS= read -r lane_dir; do
    lane_name="$(clasp_swarm_lane_name "$lane_dir")"
    runtime_root="$project_root/.clasp-swarm/$wave_name/$lane_name"
    if lane_runtime_is_running "$runtime_root"; then
      count=$((count + 1))
    fi
  done < <(clasp_swarm_lane_dirs "$wave_name" "$project_root")

  printf '%s\n' "$count"
}

validate_non_negative_integer "CLASP_SWARM_MAX_RUNNING_LANES" "$max_running_lanes"
validate_non_negative_integer "CLASP_SWARM_LANE_MEMORY_MB" "$lane_memory_mb"
validate_non_negative_integer "CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB" "$min_available_memory_mb"
validate_non_negative_integer "CLASP_SWARM_NATIVE_JOBS_MAX" "$native_jobs_max"
validate_non_negative_integer "CLASP_SWARM_NATIVE_BUNDLE_JOBS" "$native_bundle_jobs"
validate_non_negative_integer "CLASP_SWARM_NATIVE_IMAGE_SECTION_JOBS" "$native_image_section_jobs"
validate_non_negative_integer "CLASP_SWARM_NATIVE_IMAGE_SECTION_JOBS_MAX" "$native_image_section_jobs_max"
validate_non_negative_integer "CLASP_SWARM_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS" "$native_image_module_decl_fresh_process"
validate_non_negative_integer "CLASP_SWARM_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS" "$native_export_host_idle_timeout_secs"

if [[ "${1:-}" == "--list-lanes" ]]; then
  wave_name="${2:-$(clasp_swarm_default_wave)}"
  clasp_swarm_lane_dirs "$wave_name" "$project_root"
  exit 0
fi

if [[ "${1:-}" == "--list-batches" ]]; then
  wave_name="${2:-$(clasp_swarm_default_wave)}"
  batch_labels=()
  while IFS= read -r lane_dir; do
    task_files=()
    task_files_output="$(clasp_swarm_task_files "$lane_dir")"
    if [[ -n "$task_files_output" ]]; then
      mapfile -t task_files <<< "$task_files_output"
    fi

    for task_file in "${task_files[@]}"; do
      batch_label="$(clasp_swarm_task_batch_label "$task_file")"
      [[ -n "$batch_label" ]] || continue
      batch_labels+=("$batch_label")
    done
  done < <(clasp_swarm_lane_dirs "$wave_name" "$project_root")
  if [[ "${#batch_labels[@]}" -gt 0 ]]; then
    printf '%s\n' "${batch_labels[@]}" | sort -u
  fi
  exit 0
fi

if [[ "${1:-}" == "--batch" ]]; then
  if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "usage: $0 [--batch <batch-label> [wave-name]] [wave-name]" >&2
    exit 1
  fi
  batch_filter="$2"
  wave_name="${3:-$(clasp_swarm_default_wave)}"
fi

if [[ "$allow_dirty" != "1" ]] && \
   { ! git -C "$project_root" diff --quiet --ignore-submodules --exit-code || \
     ! git -C "$project_root" diff --cached --quiet --ignore-submodules --exit-code || \
     [[ -n "$(git -C "$project_root" ls-files --others --exclude-standard)" ]]; }; then
  echo "refusing to start the swarm from a dirty repo; commit or stash changes first" >&2
  exit 1
fi

current_branch="$(clasp_swarm_current_branch "$project_root")"
if [[ "$current_branch" != "$main_branch" ]]; then
  echo "refusing to start the swarm unless the repo is checked out on $main_branch; current branch is $current_branch" >&2
  exit 1
fi

if ! git -C "$project_root" show-ref --verify --quiet "refs/heads/$trunk_branch"; then
  git -C "$project_root" branch "$trunk_branch" "$source_ref"
fi

clasp_swarm_reconcile_main_and_trunk "$project_root" "$main_branch" "$trunk_branch" >/dev/null

running_lanes="$(running_lane_count_for_wave)"

while IFS= read -r lane_dir; do
  if [[ -n "$batch_filter" ]]; then
    lane_has_batch=0
    task_files=()
    task_files_output="$(clasp_swarm_task_files "$lane_dir")"
    if [[ -n "$task_files_output" ]]; then
      mapfile -t task_files <<< "$task_files_output"
    fi

    for task_file in "${task_files[@]}"; do
      if [[ "$(clasp_swarm_task_batch_label "$task_file")" == "$batch_filter" ]]; then
        lane_has_batch=1
        break
      fi
    done

    if [[ "$lane_has_batch" != "1" ]]; then
      continue
    fi
  fi

  lane_name="$(clasp_swarm_lane_name "$lane_dir")"
  runtime_root="$project_root/.clasp-swarm/$wave_name/$lane_name"
  log_file="$runtime_root/lane.log"
  pid_file="$runtime_root/pid"
  job_file="$runtime_root/job"
  completed_root="$runtime_root/completed"
  blocked_root="$runtime_root/blocked"
  global_completed_root="$project_root/.clasp-swarm/completed"

  mkdir -p "$runtime_root"

  if [[ -f "$job_file" ]]; then
    job_dir="$(sed -n '1p' "$job_file")"
    if [[ -f "$job_dir/pid" && -f "$job_dir/status" ]]; then
      pid="$(tr -d '[:space:]' <"$job_dir/pid")"
      status="$(sed -n '1p' "$job_dir/status")"
      if [[ "$status" != "completed" && "$status" != "failed" && "$status" != "stopped" ]] &&
         kill -0 "$pid" >/dev/null 2>&1; then
        echo "lane $lane_name already running with managed job pid $pid"
        continue
      fi
    fi
    rm -f "$job_file" "$pid_file"
  elif [[ -f "$pid_file" ]]; then
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" >/dev/null 2>&1; then
      echo "lane $lane_name already running with unmanaged pid $pid; refusing to overwrite raw pid state"
      continue
    fi
    rm -f "$pid_file"
  fi

  selected_task="$(
    clasp_swarm_select_next_ready_task \
      "$lane_dir" \
      "$completed_root" \
      "$global_completed_root" \
      "$blocked_root" \
      "$batch_filter" || true
  )"
  if [[ -z "$selected_task" ]]; then
    echo "lane $lane_name has no pending tasks"
    continue
  fi
  if [[ "$selected_task" == __WAIT__:* ]]; then
    echo "lane $lane_name has no ready tasks; dependencies are not complete"
    continue
  fi
  if [[ "$selected_task" == __BLOCKED__:* ]]; then
    echo "lane $lane_name is blocked; not starting"
    continue
  fi

  if (( max_running_lanes > 0 && running_lanes >= max_running_lanes )); then
    echo "resource guard: not starting lane=$lane_name; running_lanes=$running_lanes max_running_lanes=$max_running_lanes"
    continue
  fi

  required_available_memory_mb="$min_available_memory_mb"
  if (( lane_memory_mb > 0 )); then
    required_available_memory_mb=$((required_available_memory_mb + (lane_memory_mb * (running_lanes + 1))))
  fi

  if (( required_available_memory_mb > 0 )); then
    mem_available_mb="$(available_memory_mb)"
    if (( mem_available_mb < required_available_memory_mb )); then
      echo "resource guard: not starting lane=$lane_name; available_memory_mb=$mem_available_mb required_available_memory_mb=$required_available_memory_mb min_available_memory_mb=$min_available_memory_mb lane_memory_mb=$lane_memory_mb projected_running_lanes=$((running_lanes + 1))"
      continue
    fi
  fi

  managed_job_args=(
    "$project_root/scripts/run-managed-job.sh"
    --jobs-root "$runtime_root/jobs"
  )
  if (( lane_memory_mb > 0 )); then
    managed_job_args+=(--memory-mb "$lane_memory_mb")
  fi
  if (( min_available_memory_mb > 0 )); then
    managed_job_args+=(--min-available-memory-mb "$min_available_memory_mb")
  fi

  job_dir="$(
    "${managed_job_args[@]}" \
      -- bash -c 'log_file="$1"; shift; exec "$@" >>"$log_file" 2>&1' \
        managed-swarm-lane "$log_file" \
        env CLASP_SWARM_BATCH="$batch_filter" \
        CLASP_NATIVE_JOBS_MAX="$native_jobs_max" \
        CLASP_NATIVE_BUNDLE_JOBS="$native_bundle_jobs" \
        CLASP_NATIVE_IMAGE_SECTION_JOBS="$native_image_section_jobs" \
        CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX="$native_image_section_jobs_max" \
        CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS="$native_image_module_decl_fresh_process" \
        CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS="$native_export_host_idle_timeout_secs" \
        bash "$project_root/scripts/clasp-swarm-lane.sh" "$lane_dir"
  )"
  pid="$(tr -d '[:space:]' <"$job_dir/pid")"
  printf '%s\n' "$job_dir" > "$job_file"
  printf '%s\n' "$pid" > "$pid_file"
  running_lanes=$((running_lanes + 1))
  if [[ -n "$batch_filter" ]]; then
    echo "started lane=$lane_name batch=$batch_filter pid=$pid job=$job_dir log=$log_file"
  else
    echo "started lane=$lane_name pid=$pid job=$job_dir log=$log_file"
  fi
done < <(clasp_swarm_lane_dirs "$wave_name" "$project_root")
