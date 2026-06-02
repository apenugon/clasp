#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
promote_managed_mode="${CLASP_PROMOTE_MANAGED:-auto}"
promote_managed_memory_mb="${CLASP_PROMOTE_MANAGED_MEMORY_MB:-8192}"
promote_managed_min_available_memory_mb="${CLASP_PROMOTE_MANAGED_MIN_AVAILABLE_MEMORY_MB:-45056}"
promote_managed_min_available_disk_mb="${CLASP_PROMOTE_MANAGED_MIN_AVAILABLE_DISK_MB:-16384}"
promote_managed_min_disk_headroom_mb="${CLASP_PROMOTE_MANAGED_MIN_DISK_HEADROOM_MB:-${CLASP_GENERATED_STATE_MIN_HEADROOM_MB:-1024}}"
promote_managed_poll_secs="${CLASP_PROMOTE_MANAGED_POLL_SECS:-1}"

if [[ -f "$project_root/scripts/normalize-tmpdir.sh" ]]; then
  source "$project_root/scripts/normalize-tmpdir.sh"
fi

if ! [[ "$promote_managed_memory_mb" =~ ^[0-9]+$ ]]; then
  printf 'promote-selfhost-images: CLASP_PROMOTE_MANAGED_MEMORY_MB must be a non-negative integer; got %s\n' "$promote_managed_memory_mb" >&2
  exit 2
fi
if ! [[ "$promote_managed_min_available_memory_mb" =~ ^[0-9]+$ ]]; then
  printf 'promote-selfhost-images: CLASP_PROMOTE_MANAGED_MIN_AVAILABLE_MEMORY_MB must be a non-negative integer; got %s\n' "$promote_managed_min_available_memory_mb" >&2
  exit 2
fi
if ! [[ "$promote_managed_min_available_disk_mb" =~ ^[0-9]+$ ]]; then
  printf 'promote-selfhost-images: CLASP_PROMOTE_MANAGED_MIN_AVAILABLE_DISK_MB must be a non-negative integer; got %s\n' "$promote_managed_min_available_disk_mb" >&2
  exit 2
fi
if ! [[ "$promote_managed_min_disk_headroom_mb" =~ ^[0-9]+$ ]]; then
  printf 'promote-selfhost-images: CLASP_PROMOTE_MANAGED_MIN_DISK_HEADROOM_MB must be a non-negative integer; got %s\n' "$promote_managed_min_disk_headroom_mb" >&2
  exit 2
fi
if ! [[ "$promote_managed_poll_secs" =~ ^[0-9]+$ && "$promote_managed_poll_secs" -gt 0 ]]; then
  promote_managed_poll_secs=1
fi

promotion_managed_enabled() {
  case "$promote_managed_mode" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off|never|NEVER|Never)
      return 1
      ;;
  esac

  [[ "${CLASP_PROMOTE_MANAGED_REENTRY:-0}" != "1" ]] || return 1
  [[ -z "${CLASP_MANAGED_JOB_ID:-}" ]] || return 1
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

run_managed_promotion() {
  local jobs_root="$project_root/.clasp-verify/jobs"
  local job_dir=""
  local stdout_offset=0
  local stderr_offset=0
  local status=""
  local exit_status=1
  local streamed_log_offset=0
  local managed_job_terminal=0
  local managed_args=("$project_root/scripts/run-managed-job.sh" --jobs-root "$jobs_root")

  cleanup_managed_promotion() {
    local cleanup_status=""

    if [[ "$managed_job_terminal" == "1" || -z "$job_dir" || ! -d "$job_dir" ]]; then
      return 0
    fi
    cleanup_status="$(sed -n '1p' "$job_dir/status" 2>/dev/null || printf 'missing')"
    case "$cleanup_status" in
      completed|failed|stopped|memory-exceeded|disk-exceeded)
        return 0
        ;;
    esac
    if [[ -x "$project_root/scripts/stop-managed-job.sh" ]]; then
      "$project_root/scripts/stop-managed-job.sh" --jobs-root "$jobs_root" "$job_dir" >/dev/null 2>&1 || true
    fi
  }

  if (( promote_managed_memory_mb > 0 )); then
    managed_args+=(--memory-mb "$promote_managed_memory_mb")
  fi
  if (( promote_managed_min_available_memory_mb > 0 )); then
    managed_args+=(--min-available-memory-mb "$promote_managed_min_available_memory_mb")
  fi
  if (( promote_managed_min_available_disk_mb > 0 )); then
    managed_args+=(--min-available-disk-mb "$promote_managed_min_available_disk_mb" --disk-reserve-path "$project_root")
  fi
  if (( promote_managed_min_disk_headroom_mb > 0 )); then
    managed_args+=(--min-disk-headroom-mb "$promote_managed_min_disk_headroom_mb" --disk-reserve-path "$project_root")
  fi

  job_dir="$(
    "${managed_args[@]}" \
      -- env \
        CLASP_PROMOTE_MANAGED_REENTRY=1 \
        bash "$project_root/scripts/promote-selfhost-images.sh" "$@"
  )"
  printf 'promote-selfhost-images: managed promotion job: %s memory_mb=%s min_available_memory_mb=%s min_available_disk_mb=%s min_disk_headroom_mb=%s\n' \
    "$job_dir" "$promote_managed_memory_mb" "$promote_managed_min_available_memory_mb" "$promote_managed_min_available_disk_mb" "$promote_managed_min_disk_headroom_mb" >&2
  trap cleanup_managed_promotion EXIT INT TERM HUP

  while true; do
    stream_managed_log_growth "$job_dir/stdout.log" "$stdout_offset" 1
    stdout_offset="$streamed_log_offset"
    stream_managed_log_growth "$job_dir/stderr.log" "$stderr_offset" 2
    stderr_offset="$streamed_log_offset"
    status="$(sed -n '1p' "$job_dir/status" 2>/dev/null || printf 'missing')"
    case "$status" in
      completed|failed|stopped|memory-exceeded|disk-exceeded)
        managed_job_terminal=1
        break
        ;;
    esac
    sleep "$promote_managed_poll_secs"
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
    printf 'promote-selfhost-images: managed promotion memory guard tripped:\n' >&2
    sed 's/^/  /' "$job_dir/memory-exceeded" >&2 || true
  fi
  if [[ -f "$job_dir/disk-exceeded" ]]; then
    printf 'promote-selfhost-images: managed promotion disk guard tripped:\n' >&2
    sed 's/^/  /' "$job_dir/disk-exceeded" >&2 || true
  fi

  exit "$exit_status"
}

if promotion_managed_enabled; then
  run_managed_promotion "$@"
fi

cd "$project_root"

export CLASP_PROJECT_ROOT="$project_root"
export CLASP_NATIVE_BUNDLE_JOBS="${CLASP_NATIVE_BUNDLE_JOBS:-1}"
export CLASP_NATIVE_IMAGE_SECTION_JOBS="${CLASP_NATIVE_IMAGE_SECTION_JOBS:-1}"
export CLASP_NATIVE_JOBS_MAX="${CLASP_NATIVE_JOBS_MAX:-1}"
export CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX="${CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX:-1}"
export CLASP_NATIVE_DISABLE_EXPORT_HOST="${CLASP_NATIVE_DISABLE_EXPORT_HOST:-1}"
export CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS="${CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS:-1}"
export CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE="${CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE:-8}"
export CLASP_NATIVE_IMAGE_LEGACY_NAMED_DECL_CHUNK_SIZE="${CLASP_NATIVE_IMAGE_LEGACY_NAMED_DECL_CHUNK_SIZE:-4}"

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN "$project_root/scripts/resolve-claspc.sh")"
tmp_compiler="$(mktemp -p "$project_root/src" .stage1.compiler.native.image.json.XXXXXX)"
tmp_promoted="$(mktemp -p "$project_root/src" .embedded.native.image.json.XXXXXX)"

cleanup() {
  rm -f "$tmp_compiler" "$tmp_promoted"
}

trap cleanup EXIT

validate_image() {
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$1" >/dev/null
}

"$claspc_bin" --json native-image "$project_root/src/CompilerMain.clasp" -o "$tmp_compiler"
validate_image "$tmp_compiler"
mv "$tmp_compiler" "$project_root/src/stage1.compiler.native.image.json"
cp "$project_root/src/stage1.compiler.native.image.json" "$project_root/src/embedded.compiler.native.image.json"

"$claspc_bin" --json native-image "$project_root/src/Main.clasp" -o "$tmp_promoted"
validate_image "$tmp_promoted"
mv "$tmp_promoted" "$project_root/src/embedded.native.image.json"

env -u CLASP_CLASPC -u CLASPC_BIN "$project_root/scripts/resolve-claspc.sh" >/dev/null
node "$project_root/scripts/generate-promoted-module-summary-cache.mjs"
node "$project_root/scripts/generate-promoted-source-export-cache.mjs" --refresh-native-images
node "$project_root/scripts/check-promoted-native-image-exports.mjs"
