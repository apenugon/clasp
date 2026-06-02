#!/usr/bin/env bash
set -euo pipefail

ulimit -c 0 >/dev/null 2>&1 || true

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

affected_managed_mode="${CLASP_VERIFY_AFFECTED_MANAGED:-${CLASP_VERIFY_MANAGED:-auto}}"
affected_managed_memory_mb="${CLASP_VERIFY_AFFECTED_MEMORY_MB:-${CLASP_VERIFY_MANAGED_MEMORY_MB:-8192}}"
affected_managed_min_available_memory_mb="${CLASP_VERIFY_AFFECTED_MIN_AVAILABLE_MEMORY_MB:-${CLASP_VERIFY_MANAGED_MIN_AVAILABLE_MEMORY_MB:-45056}}"
affected_managed_min_available_disk_mb="${CLASP_VERIFY_AFFECTED_MIN_AVAILABLE_DISK_MB:-${CLASP_VERIFY_MANAGED_MIN_AVAILABLE_DISK_MB:-16384}}"
affected_managed_min_disk_headroom_mb="${CLASP_VERIFY_AFFECTED_MIN_DISK_HEADROOM_MB:-${CLASP_VERIFY_MANAGED_MIN_DISK_HEADROOM_MB:-${CLASP_GENERATED_STATE_MIN_HEADROOM_MB:-1024}}}"
affected_managed_poll_secs="${CLASP_VERIFY_AFFECTED_POLL_SECS:-${CLASP_VERIFY_MANAGED_POLL_SECS:-1}}"
affected_direct_memory_limit="${CLASP_VERIFY_AFFECTED_DIRECT_MEMORY_LIMIT:-${CLASP_VERIFY_DIRECT_MEMORY_LIMIT:-auto}}"
affected_direct_memory_limit_mb="${CLASP_VERIFY_AFFECTED_DIRECT_MEMORY_LIMIT_MB:-${CLASP_VERIFY_DIRECT_MEMORY_LIMIT_MB:-$affected_managed_memory_mb}}"
affected_direct_host_reserve="${CLASP_VERIFY_AFFECTED_DIRECT_HOST_RESERVE:-${CLASP_VERIFY_DIRECT_HOST_RESERVE:-auto}}"
affected_label="${CLASP_VERIFY_AFFECTED_LABEL:-verify-affected}"
affected_jobs_root="${CLASP_VERIFY_AFFECTED_JOBS_ROOT:-${CLASP_VERIFY_TMPDIR:-${TMPDIR:-/tmp}}/clasp-verify-affected-jobs}"

if ! [[ "$affected_managed_memory_mb" =~ ^[0-9]+$ ]]; then
  printf '%s: CLASP_VERIFY_AFFECTED_MEMORY_MB must be a non-negative integer; got %s\n' \
    "$affected_label" "$affected_managed_memory_mb" >&2
  exit 2
fi
if ! [[ "$affected_managed_min_available_memory_mb" =~ ^[0-9]+$ ]]; then
  printf '%s: CLASP_VERIFY_AFFECTED_MIN_AVAILABLE_MEMORY_MB must be a non-negative integer; got %s\n' \
    "$affected_label" "$affected_managed_min_available_memory_mb" >&2
  exit 2
fi
if ! [[ "$affected_managed_min_available_disk_mb" =~ ^[0-9]+$ ]]; then
  printf '%s: CLASP_VERIFY_AFFECTED_MIN_AVAILABLE_DISK_MB must be a non-negative integer; got %s\n' \
    "$affected_label" "$affected_managed_min_available_disk_mb" >&2
  exit 2
fi
if ! [[ "$affected_managed_min_disk_headroom_mb" =~ ^[0-9]+$ ]]; then
  printf '%s: CLASP_VERIFY_AFFECTED_MIN_DISK_HEADROOM_MB must be a non-negative integer; got %s\n' \
    "$affected_label" "$affected_managed_min_disk_headroom_mb" >&2
  exit 2
fi
if ! [[ "$affected_managed_poll_secs" =~ ^[0-9]+$ && "$affected_managed_poll_secs" -gt 0 ]]; then
  affected_managed_poll_secs=1
fi
if ! [[ "$affected_direct_memory_limit_mb" =~ ^[0-9]+$ ]]; then
  printf '%s: CLASP_VERIFY_AFFECTED_DIRECT_MEMORY_LIMIT_MB must be a non-negative integer; got %s\n' \
    "$affected_label" "$affected_direct_memory_limit_mb" >&2
  exit 2
fi

affected_managed_enabled() {
  case "$affected_managed_mode" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off|never|NEVER|Never)
      return 1
      ;;
  esac

  [[ "${CLASP_VERIFY_AFFECTED_MANAGED_REENTRY:-0}" != "1" ]] || return 1
  [[ -z "${CLASP_MANAGED_JOB_ID:-}" ]] || return 1
  [[ "${CLASP_VERIFY_USE_CURRENT_SHELL:-0}" != "1" ]] || return 1
  [[ -x "$project_root/scripts/run-managed-job.sh" ]] || return 1
  return 0
}

affected_direct_memory_limit_enabled() {
  case "$affected_direct_memory_limit" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off|never|NEVER|Never)
      return 1
      ;;
  esac

  (( affected_direct_memory_limit_mb > 0 )) || return 1
  [[ "${CLASP_VERIFY_AFFECTED_MANAGED_REENTRY:-0}" != "1" ]] || return 1
  [[ -z "${CLASP_MANAGED_JOB_ID:-}" ]] || return 1
  return 0
}

apply_affected_direct_memory_limit() {
  local requested_kb=0
  local current_limit=""

  affected_direct_memory_limit_enabled || return 0

  requested_kb=$((affected_direct_memory_limit_mb * 1024))
  current_limit="$(ulimit -v 2>/dev/null || printf 'unlimited')"

  if [[ "$current_limit" =~ ^[0-9]+$ ]] && (( current_limit <= requested_kb )); then
    return 0
  fi

  if ! ulimit -v "$requested_kb" >/dev/null 2>&1; then
    printf '%s: failed to apply direct affected verification memory limit: %s MB\n' "$affected_label" "$affected_direct_memory_limit_mb" >&2
    exit 2
  fi
}

affected_memory_available_mb() {
  awk '/MemAvailable:/ { printf "%d\n", int($2 / 1024); found = 1 } END { if (!found) print 0 }' /proc/meminfo 2>/dev/null ||
    printf '0\n'
}

affected_disk_available_mb() {
  df -Pm "$project_root" 2>/dev/null |
    awk 'NR == 2 { printf "%d\n", $4; found = 1 } END { if (!found) print 0 }' ||
    printf '0\n'
}

affected_direct_host_reserve_enabled() {
  case "$affected_direct_host_reserve" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off|never|NEVER|Never)
      return 1
      ;;
  esac

  [[ "${CLASP_VERIFY_AFFECTED_MANAGED_REENTRY:-0}" != "1" ]] || return 1
  [[ -z "${CLASP_MANAGED_JOB_ID:-}" ]] || return 1
  return 0
}

preflight_affected_direct_host_resources() {
  local available_memory_mb=0
  local available_disk_mb=0
  local disk_headroom_mb=0

  affected_direct_host_reserve_enabled || return 0

  if (( affected_managed_min_available_memory_mb > 0 )); then
    available_memory_mb="$(affected_memory_available_mb)"
    if ! [[ "$available_memory_mb" =~ ^[0-9]+$ ]]; then
      available_memory_mb=0
    fi
    if (( available_memory_mb < affected_managed_min_available_memory_mb )); then
      printf '%s: direct affected verification memory guard tripped: available_memory_mb=%s min_available_memory_mb=%s\n' \
        "$affected_label" "$available_memory_mb" "$affected_managed_min_available_memory_mb" >&2
      exit 75
    fi
  fi

  if (( affected_managed_min_available_disk_mb > 0 || affected_managed_min_disk_headroom_mb > 0 )); then
    available_disk_mb="$(affected_disk_available_mb)"
    if ! [[ "$available_disk_mb" =~ ^[0-9]+$ ]]; then
      available_disk_mb=0
    fi
    if (( affected_managed_min_available_disk_mb > 0 && available_disk_mb < affected_managed_min_available_disk_mb )); then
      printf '%s: direct affected verification disk guard tripped: available_disk_mb=%s min_available_disk_mb=%s\n' \
        "$affected_label" "$available_disk_mb" "$affected_managed_min_available_disk_mb" >&2
      exit 75
    fi
    if (( affected_managed_min_disk_headroom_mb > 0 )); then
      disk_headroom_mb=$((available_disk_mb - affected_managed_min_available_disk_mb))
      if (( disk_headroom_mb < affected_managed_min_disk_headroom_mb )); then
        printf '%s: direct affected verification disk guard tripped: available_disk_mb=%s min_available_disk_mb=%s disk_headroom_mb=%s min_disk_headroom_mb=%s\n' \
          "$affected_label" "$available_disk_mb" "$affected_managed_min_available_disk_mb" "$disk_headroom_mb" "$affected_managed_min_disk_headroom_mb" >&2
        exit 75
      fi
    fi
  fi
}

for arg in "$@"; do
  if [[ "$arg" == "--plan-only" ]]; then
    apply_affected_direct_memory_limit
    exec node "$project_root/scripts/verify-affected.mjs" "$@"
  fi
done

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

run_managed_affected_verification() {
  local jobs_root="$affected_jobs_root"
  local job_dir=""
  local stdout_offset=0
  local stderr_offset=0
  local status=""
  local exit_status=1
  local streamed_log_offset=0
  local managed_args=("$project_root/scripts/run-managed-job.sh" --jobs-root "$jobs_root")

  if (( affected_managed_memory_mb > 0 )); then
    managed_args+=(--memory-mb "$affected_managed_memory_mb")
  fi
  if (( affected_managed_min_available_memory_mb > 0 )); then
    managed_args+=(--min-available-memory-mb "$affected_managed_min_available_memory_mb")
  fi
  if (( affected_managed_min_available_disk_mb > 0 )); then
    managed_args+=(--min-available-disk-mb "$affected_managed_min_available_disk_mb" --disk-reserve-path "$project_root")
  fi
  if (( affected_managed_min_disk_headroom_mb > 0 )); then
    managed_args+=(--min-disk-headroom-mb "$affected_managed_min_disk_headroom_mb" --disk-reserve-path "$project_root")
  fi

  job_dir="$(
    "${managed_args[@]}" \
      -- env \
        CLASP_VERIFY_AFFECTED_MANAGED_REENTRY=1 \
        CLASP_NATIVE_JOBS_MAX="${CLASP_NATIVE_JOBS_MAX:-1}" \
        CLASP_NATIVE_BUNDLE_JOBS="${CLASP_NATIVE_BUNDLE_JOBS:-1}" \
        CLASP_NATIVE_IMAGE_SECTION_JOBS="${CLASP_NATIVE_IMAGE_SECTION_JOBS:-1}" \
        CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX="${CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX:-1}" \
        CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS="${CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS:-1}" \
        CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE="${CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE:-8}" \
        CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS="${CLASP_NATIVE_EXPORT_HOST_IDLE_TIMEOUT_SECS:-5}" \
        node "$project_root/scripts/verify-affected.mjs" "$@"
  )"
  printf '%s: managed affected verification job: %s memory_mb=%s min_available_memory_mb=%s min_available_disk_mb=%s min_disk_headroom_mb=%s\n' \
    "$affected_label" "$job_dir" "$affected_managed_memory_mb" "$affected_managed_min_available_memory_mb" "$affected_managed_min_available_disk_mb" "$affected_managed_min_disk_headroom_mb" >&2

  while true; do
    stream_managed_log_growth "$job_dir/stdout.log" "$stdout_offset" 1
    stdout_offset="$streamed_log_offset"
    stream_managed_log_growth "$job_dir/stderr.log" "$stderr_offset" 2
    stderr_offset="$streamed_log_offset"
    status="$(sed -n '1p' "$job_dir/status" 2>/dev/null || printf 'missing')"
    case "$status" in
      completed|failed|stopped|memory-exceeded|disk-exceeded)
        break
        ;;
    esac
    sleep "$affected_managed_poll_secs"
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
    printf '%s: managed affected verification memory guard tripped:\n' "$affected_label" >&2
    sed 's/^/  /' "$job_dir/memory-exceeded" >&2 || true
  fi
  if [[ -f "$job_dir/disk-exceeded" ]]; then
    printf '%s: managed affected verification disk guard tripped:\n' "$affected_label" >&2
    sed 's/^/  /' "$job_dir/disk-exceeded" >&2 || true
  fi

  exit "$exit_status"
}

if affected_managed_enabled; then
  run_managed_affected_verification "$@"
fi

preflight_affected_direct_host_resources
apply_affected_direct_memory_limit
exec node "$project_root/scripts/verify-affected.mjs" "$@"
