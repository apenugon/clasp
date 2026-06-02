#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
apply=0
health=0
json=0
include_run_binary_cache=0
include_temp_caches=0
include_test_tmpdirs=0
include_build_caches=0
include_codex_logs=0
temp_only=0
verbose=0
min_available_disk_mb="${CLASP_GENERATED_STATE_MIN_AVAILABLE_DISK_MB:-${CLASP_VERIFY_MANAGED_MIN_AVAILABLE_DISK_MB:-16384}}"
min_disk_headroom_mb="${CLASP_GENERATED_STATE_MIN_HEADROOM_MB:-1024}"
disk_reserve_path="${CLASP_GENERATED_STATE_DISK_RESERVE_PATH:-$project_root}"
generated_state_tmpdir="${CLASP_GENERATED_STATE_TMPDIR:-${TMPDIR:-/tmp}}"
generated_state_global_cache_dir="${CLASP_GENERATED_STATE_GLOBAL_CACHE_DIR:-/tmp/clasp-nix-cache}"
codex_home="${CODEX_HOME:-$HOME/.codex}"
codex_log_path="${CLASP_GENERATED_STATE_CODEX_LOG_PATH:-$codex_home/log/codex-tui.log}"
codex_log_max_bytes="${CLASP_GENERATED_STATE_CODEX_LOG_MAX_BYTES:-33554432}"

usage() {
  cat <<'EOF' >&2
usage: scripts/clasp-clean-generated-state.sh [--apply] [--health] [--json] [--temp-only] [--include-run-binary-cache] [--include-temp-caches] [--include-test-tmpdirs] [--include-build-caches] [--include-codex-logs] [--min-available-disk-mb <mb>] [--min-disk-headroom-mb <mb>] [--disk-reserve-path <path>] [--verbose]

Safely removes stale generated state from ignored Clasp runtime directories.
It also removes known ignored benchmark/dist outputs that are fully rebuildable.
Without --apply, prints what would be removed.
With --health, prints a non-destructive resource/cleanup preflight report.

The script refuses to remove anything if it finds an actually-running generated
job or loop pid under .clasp-swarm, .clasp-agents, .clasp-loops, or .clasp-verify.
Stale pid/job metadata is considered removable.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      apply=1
      shift
      ;;
    --health)
      health=1
      apply=0
      shift
      ;;
    --json)
      json=1
      shift
      ;;
    --dry-run)
      apply=0
      shift
      ;;
    --include-run-binary-cache)
      include_run_binary_cache=1
      shift
      ;;
    --include-temp-caches)
      include_temp_caches=1
      shift
      ;;
    --include-test-tmpdirs)
      include_test_tmpdirs=1
      shift
      ;;
    --include-build-caches)
      include_build_caches=1
      shift
      ;;
    --include-codex-logs)
      include_codex_logs=1
      shift
      ;;
    --temp-only)
      temp_only=1
      shift
      ;;
    --verbose)
      verbose=1
      shift
      ;;
    --min-available-disk-mb)
      min_available_disk_mb="${2:-}"
      shift 2
      ;;
    --min-disk-headroom-mb)
      min_disk_headroom_mb="${2:-}"
      shift 2
      ;;
    --disk-reserve-path)
      disk_reserve_path="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

cd "$project_root"

if ! [[ "$min_available_disk_mb" =~ ^[0-9]+$ ]]; then
  printf 'CLASP_GENERATED_STATE_MIN_AVAILABLE_DISK_MB must be a non-negative integer; got %s\n' "$min_available_disk_mb" >&2
  exit 2
fi
if ! [[ "$min_disk_headroom_mb" =~ ^[0-9]+$ ]]; then
  printf 'CLASP_GENERATED_STATE_MIN_HEADROOM_MB must be a non-negative integer; got %s\n' "$min_disk_headroom_mb" >&2
  exit 2
fi
if ! [[ "$codex_log_max_bytes" =~ ^[0-9]+$ ]]; then
  printf 'CLASP_GENERATED_STATE_CODEX_LOG_MAX_BYTES must be a non-negative integer; got %s\n' "$codex_log_max_bytes" >&2
  exit 2
fi
if [[ -z "$disk_reserve_path" ]]; then
  printf 'disk reserve path must not be empty\n' >&2
  exit 2
fi

generated_roots=(
  ".clasp-swarm"
  ".clasp-agents"
  ".clasp-loops"
  ".clasp-verify"
)

is_terminal_job_status() {
  case "$1" in
    completed|failed|stopped|memory-exceeded|disk-exceeded|memory-enforcer-unavailable|admission-lock-unavailable)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

pid_is_alive() {
  local pid="$1"

  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

path_is_under_generated_root() {
  local path="$1"
  case "$path" in
    .clasp-swarm/*|.clasp-agents/*|.clasp-loops/*|.clasp-verify/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

path_is_known_ignored_generated_output() {
  local path="$1"
  case "$path" in
    benchmarks/workspaces/*|benchmarks/results/*|dist)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

active_generated_processes() {
  local root
  local pid_file
  local pid
  local job_dir
  local status

  for root in "${generated_roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r pid_file; do
      [[ -f "$pid_file" ]] || continue
      pid="$(tr -d '[:space:]' <"$pid_file" 2>/dev/null || true)"
      [[ -n "$pid" ]] || continue

      job_dir="$(dirname "$pid_file")"
      status=""
      if [[ -f "$job_dir/status" ]]; then
        status="$(sed -n '1p' "$job_dir/status" 2>/dev/null || true)"
      fi
      if [[ -n "$status" ]] && is_terminal_job_status "$status"; then
        continue
      fi

      if pid_is_alive "$pid"; then
        printf '%s\t%s\t%s\n' "$pid" "$pid_file" "${status:-unknown}"
      fi
    done < <(find "$root" -type f \( -name pid -o -name '*.pid' \) 2>/dev/null | sort)
  done
}

append_target_if_exists() {
  local path="$1"

  [[ -e "$path" ]] || return 0
  if ! path_is_under_generated_root "$path" && ! path_is_known_ignored_generated_output "$path"; then
    return 0
  fi
  cleanup_targets+=("$path")
}

append_find_targets() {
  local root="$1"
  local name="$2"

  [[ -d "$root" ]] || return 0
  while IFS= read -r path; do
    append_target_if_exists "$path"
  done < <(find "$root" -mindepth 1 -type d -name "$name" 2>/dev/null | sort)
}

append_ignored_child_targets() {
  local root="$1"

  [[ -d "$root" ]] || return 0
  while IFS= read -r path; do
    append_target_if_exists "$path"
  done < <(find "$root" -mindepth 1 -maxdepth 1 ! -name .gitkeep 2>/dev/null | sort)
}

append_temp_target_if_exists() {
  local path="$1"

  [[ -e "$path" ]] || return 0
  temp_cleanup_targets+=("$path")
}

append_temp_child_targets_named() {
  local root="$1"
  local name="$2"

  [[ -d "$root" ]] || return 0
  while IFS= read -r path; do
    append_temp_target_if_exists "$path"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -name "$name" 2>/dev/null | sort)
}

append_clasp_test_tmpdir_targets() {
  [[ -d "$generated_state_tmpdir" ]] || return 0
  while IFS= read -r path; do
    append_temp_target_if_exists "$path"
  done < <(find "$generated_state_tmpdir" -mindepth 1 -maxdepth 1 -type d -name 'test-*.??????' 2>/dev/null | sort)
}

append_temp_cache_targets() {
  append_temp_target_if_exists "$generated_state_tmpdir/clasp-test-xdg-cache"
  append_temp_target_if_exists "$generated_state_tmpdir/clasp-verify-affected-jobs"
  append_temp_target_if_exists "$generated_state_tmpdir/clasp-test-selfhost-cache"
  append_temp_target_if_exists "$generated_state_global_cache_dir"
  append_temp_child_targets_named "$generated_state_tmpdir" "nix-shell.*"
  append_temp_child_targets_named "$generated_state_tmpdir" "nix-develop-*"
  append_temp_child_targets_named "$generated_state_tmpdir" "native-runtime-trace.*"
  append_temp_child_targets_named "$generated_state_tmpdir" "context-pack-js.*"
}

append_build_target_if_exists() {
  local path="$1"

  [[ -e "$path" ]] || return 0
  build_cleanup_targets+=("$path")
}

append_build_cache_targets() {
  append_build_target_if_exists "runtime/target"
  append_build_target_if_exists "dist-newstyle"
}

run_binary_cache_dir() {
  if [[ -n "${CLASP_NATIVE_RUN_BINARY_CACHE_DIR:-}" ]]; then
    printf '%s\n' "$CLASP_NATIVE_RUN_BINARY_CACHE_DIR"
  elif [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    printf '%s\n' "$XDG_CACHE_HOME/claspc-native/run-binary-cache-v2"
  else
    printf '%s\n' "/tmp/clasp-nix-cache/claspc-native/run-binary-cache-v2"
  fi
}

human_size() {
  local path="$1"

  du -sh "$path" 2>/dev/null | awk '{print $1}' || printf '0'
}

size_mb() {
  local path="$1"
  local size_kb

  [[ -e "$path" ]] || {
    printf '0\n'
    return 0
  }
  size_kb="$(du -sk -- "$path" 2>/dev/null | awk '{ print $1; found = 1 } END { if (!found) print 0 }')"
  if [[ "$size_kb" =~ ^[0-9]+$ ]]; then
    printf '%d\n' "$(((size_kb + 1023) / 1024))"
  else
    printf '0\n'
  fi
}

sum_size_mb() {
  local total=0
  local target
  local target_size_mb

  for target in "$@"; do
    target_size_mb="$(size_mb "$target")"
    if [[ "$target_size_mb" =~ ^[0-9]+$ ]]; then
      total="$((total + target_size_mb))"
    fi
  done
  printf '%d\n' "$total"
}

file_size_bytes() {
  local path="$1"

  [[ -f "$path" ]] || {
    printf '0\n'
    return 0
  }
  stat -c '%s' -- "$path" 2>/dev/null || printf '0\n'
}

bytes_to_mb_ceil() {
  local bytes="$1"

  if [[ "$bytes" =~ ^[0-9]+$ ]]; then
    printf '%d\n' "$(((bytes + 1048575) / 1048576))"
  else
    printf '0\n'
  fi
}

cap_log_file_tail() {
  local path="$1"
  local max_bytes="$2"
  local size_bytes
  local tmp_path

  [[ -f "$path" ]] || return 0
  [[ "$max_bytes" =~ ^[0-9]+$ ]] || return 0
  size_bytes="$(file_size_bytes "$path")"
  [[ "$size_bytes" =~ ^[0-9]+$ ]] || return 0
  (( size_bytes > max_bytes )) || return 0

  tmp_path="${path}.tail.$$"
  tail -c "$max_bytes" "$path" >"$tmp_path"
  : >"$path"
  cat "$tmp_path" >>"$path"
  rm -f "$tmp_path"
}

absolute_cleanup_path() {
  local path="$1"

  case "$path" in
    /*)
      printf '%s\n' "${path%/}"
      ;;
    *)
      printf '%s/%s\n' "${project_root%/}" "${path%/}"
      ;;
  esac
}

path_is_same_or_under() {
  local child="${1%/}"
  local parent="${2%/}"

  [[ "$child" == "$parent" || "$child" == "$parent/"* ]]
}

target_covers_path() {
  local target_abs
  local path_abs

  target_abs="$(absolute_cleanup_path "$1")"
  path_abs="$(absolute_cleanup_path "$2")"
  path_is_same_or_under "$path_abs" "$target_abs"
}

cache_dir_is_covered_by_target() {
  local target

  [[ -n "$cache_dir" ]] || return 1
  for target in "${cleanup_targets[@]}" "${temp_cleanup_targets[@]}" "${build_cleanup_targets[@]}"; do
    if target_covers_path "$target" "$cache_dir"; then
      return 0
    fi
  done
  return 1
}

disk_available_mb() {
  local path="$1"

  df -Pm "$path" 2>/dev/null |
    awk 'NR == 2 { printf "%d\n", $4; found = 1 } END { if (!found) print 0 }' ||
    printf '0\n'
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

print_json_report() {
  local mode="$1"
  local safe_to_clean="$2"
  local available_disk_mb="$3"
  local reserve_met="$4"
  local cache_dir="$5"
  local disk_headroom_mb="$6"
  local disk_shortfall_mb="$7"
  local disk_low_headroom="$8"
  local recommended_action="$9"
  local first=1
  local target
  local pid
  local pid_path
  local status

  printf '{\n'
  printf '  "schemaVersion": 1,\n'
  printf '  "mode": %s,\n' "$(json_string "$mode")"
  printf '  "projectRoot": %s,\n' "$(json_string "$project_root")"
  printf '  "safeToClean": %s,\n' "$safe_to_clean"
  printf '  "repoGeneratedTargetCount": %s,\n' "${#cleanup_targets[@]}"
  printf '  "repoGeneratedTargets": ['
  for target in "${cleanup_targets[@]}"; do
    if [[ "$first" == "1" ]]; then
      first=0
      printf '\n'
    else
      printf ',\n'
    fi
    printf '    %s' "$(json_string "$target")"
  done
  if [[ "$first" == "0" ]]; then
    printf '\n  ],\n'
  else
    printf '],\n'
  fi
  printf '  "tempGeneratedTargetCount": %s,\n' "${#temp_cleanup_targets[@]}"
  printf '  "tempGeneratedTargets": ['
  first=1
  for target in "${temp_cleanup_targets[@]}"; do
    if [[ "$first" == "1" ]]; then
      first=0
      printf '\n'
    else
      printf ',\n'
    fi
    printf '    %s' "$(json_string "$target")"
  done
  if [[ "$first" == "0" ]]; then
    printf '\n  ],\n'
  else
    printf '],\n'
  fi
  printf '  "tempCacheScanIncluded": %s,\n' "$([[ "$include_temp_caches" == "1" ]] && printf true || printf false)"
  printf '  "testTmpdirScanIncluded": %s,\n' "$([[ "$include_test_tmpdirs" == "1" ]] && printf true || printf false)"
  printf '  "buildCacheScanIncluded": %s,\n' "$([[ "$include_build_caches" == "1" ]] && printf true || printf false)"
  printf '  "buildCacheTargetCount": %s,\n' "${#build_cleanup_targets[@]}"
  printf '  "buildCacheTargets": ['
  first=1
  for target in "${build_cleanup_targets[@]}"; do
    if [[ "$first" == "1" ]]; then
      first=0
      printf '\n'
    else
      printf ',\n'
    fi
    printf '    %s' "$(json_string "$target")"
  done
  if [[ "$first" == "0" ]]; then
    printf '\n  ],\n'
  else
    printf '],\n'
  fi
  printf '  "runBinaryCacheIncluded": %s,\n' "$([[ -n "$cache_dir" ]] && printf true || printf false)"
  printf '  "runBinaryCache": %s,\n' "$(json_string "$cache_dir")"
  printf '  "codexLogIncluded": %s,\n' "$([[ "$include_codex_logs" == "1" ]] && printf true || printf false)"
  printf '  "codexLog": {\n'
  printf '    "path": %s,\n' "$(json_string "$codex_log_path")"
  printf '    "exists": %s,\n' "$codex_log_exists"
  printf '    "sizeBytes": %s,\n' "$codex_log_size_bytes"
  printf '    "maxBytes": %s,\n' "$codex_log_max_bytes"
  printf '    "reclaimableMb": %s\n' "$codex_log_reclaimable_mb"
  printf '  },\n'
  printf '  "recommendedAction": %s,\n' "$(json_string "$recommended_action")"
  printf '  "cleanup": {\n'
  printf '    "repoReclaimableMb": %s,\n' "$repo_reclaimable_mb"
  printf '    "tempReclaimableMb": %s,\n' "$temp_reclaimable_mb"
  printf '    "buildCacheReclaimableMb": %s,\n' "$build_cache_reclaimable_mb"
  printf '    "runBinaryCacheReclaimableMb": %s,\n' "$run_binary_cache_reclaimable_mb"
  printf '    "codexLogReclaimableMb": %s,\n' "$codex_log_reclaimable_mb"
  printf '    "totalReclaimableMb": %s,\n' "$total_reclaimable_mb"
  printf '    "projectedAvailableMb": %s,\n' "$projected_available_disk_mb"
  printf '    "reserveRequiredMb": %s,\n' "$min_available_disk_mb"
  printf '    "guardRequiredMb": %s,\n' "$disk_guard_required_mb"
  printf '    "reserveShortfallAfterCleanupMb": %s,\n' "$reserve_shortfall_after_cleanup_mb"
  printf '    "guardShortfallAfterCleanupMb": %s,\n' "$guard_shortfall_after_cleanup_mb"
  printf '    "cleanupCanSatisfyReserve": %s,\n' "$cleanup_can_satisfy_reserve"
  printf '    "cleanupCanSatisfyGuard": %s\n' "$cleanup_can_satisfy_guard"
  printf '  },\n'
  printf '  "disk": {\n'
  printf '    "reservePath": %s,\n' "$(json_string "$disk_reserve_path")"
  printf '    "availableMb": %s,\n' "$available_disk_mb"
  printf '    "requiredMb": %s,\n' "$min_available_disk_mb"
  printf '    "minHeadroomMb": %s,\n' "$min_disk_headroom_mb"
  printf '    "headroomMb": %s,\n' "$disk_headroom_mb"
  printf '    "shortfallMb": %s,\n' "$disk_shortfall_mb"
  printf '    "lowHeadroom": %s,\n' "$disk_low_headroom"
  printf '    "reserveMet": %s\n' "$reserve_met"
  printf '  },\n'
  printf '  "activeProcessCount": %s,\n' "$active_count"
  printf '  "activeProcesses": ['
  first=1
  if [[ -n "$active_report" ]]; then
    while IFS=$'\t' read -r pid pid_path status; do
      [[ -n "$pid" ]] || continue
      if [[ "$first" == "1" ]]; then
        first=0
        printf '\n'
      else
        printf ',\n'
      fi
      printf '    {"pid": %s, "path": %s, "status": %s}' \
        "$(json_string "$pid")" \
        "$(json_string "$pid_path")" \
        "$(json_string "$status")"
    done <<<"$active_report"
  fi
  if [[ "$first" == "0" ]]; then
    printf '\n  ]\n'
  else
    printf ']\n'
  fi
  printf '}\n'
}

cleanup_targets=()
temp_cleanup_targets=()
build_cleanup_targets=()
if [[ "$temp_only" != "1" ]]; then
  append_find_targets ".clasp-swarm" "runs"
  append_find_targets ".clasp-swarm" "jobs"
  append_find_targets ".clasp-agents" "runs"
  append_find_targets ".clasp-agents" "jobs"
  append_find_targets ".clasp-loops" "runs"
  append_find_targets ".clasp-loops" "jobs"
  append_find_targets ".clasp-verify" "jobs"
  append_ignored_child_targets "benchmarks/workspaces"
  append_ignored_child_targets "benchmarks/results"
  append_target_if_exists "dist"
fi
if [[ "$include_temp_caches" == "1" ]]; then
  append_temp_cache_targets
fi
if [[ "$include_test_tmpdirs" == "1" ]]; then
  append_clasp_test_tmpdir_targets
fi
if [[ "$include_build_caches" == "1" ]]; then
  append_build_cache_targets
fi

active_report=""
if [[ "$temp_only" != "1" ]]; then
  active_report="$(active_generated_processes)"
fi
active_count=0
if [[ -n "$active_report" ]]; then
  active_count="$(printf '%s\n' "$active_report" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
fi
available_disk_mb="$(disk_available_mb "$disk_reserve_path")"
reserve_met=false
disk_low_headroom=false
disk_headroom_mb=0
disk_shortfall_mb=0
if [[ "$available_disk_mb" =~ ^[0-9]+$ ]] && (( available_disk_mb >= min_available_disk_mb )); then
  reserve_met=true
fi
if [[ "$available_disk_mb" =~ ^[0-9]+$ ]]; then
  disk_headroom_mb="$((available_disk_mb - min_available_disk_mb))"
  if (( disk_headroom_mb < 0 )); then
    disk_shortfall_mb="$((-disk_headroom_mb))"
  fi
fi
if [[ "$reserve_met" == "true" ]] && (( disk_headroom_mb < min_disk_headroom_mb )); then
  disk_low_headroom=true
fi
safe_to_clean=true
if [[ "$active_count" =~ ^[0-9]+$ ]] && (( active_count > 0 )); then
  safe_to_clean=false
fi

cache_dir=""
if [[ "$include_run_binary_cache" == "1" ]]; then
  cache_dir="$(run_binary_cache_dir)"
fi

codex_log_exists=false
codex_log_size_bytes=0
codex_log_reclaimable_mb=0
if [[ "$include_codex_logs" == "1" && -f "$codex_log_path" ]]; then
  codex_log_exists=true
  codex_log_size_bytes="$(file_size_bytes "$codex_log_path")"
  if [[ "$codex_log_size_bytes" =~ ^[0-9]+$ && "$codex_log_max_bytes" =~ ^[0-9]+$ && "$codex_log_size_bytes" -gt "$codex_log_max_bytes" ]]; then
    codex_log_reclaimable_mb="$(bytes_to_mb_ceil "$((codex_log_size_bytes - codex_log_max_bytes))")"
  fi
fi

cleanup_target_count="${#cleanup_targets[@]}"
if [[ "$include_temp_caches" == "1" ]]; then
  cleanup_target_count="$((cleanup_target_count + ${#temp_cleanup_targets[@]}))"
fi
if [[ "$include_build_caches" == "1" ]]; then
  cleanup_target_count="$((cleanup_target_count + ${#build_cleanup_targets[@]}))"
fi
if [[ -n "$cache_dir" ]]; then
  cleanup_target_count="$((cleanup_target_count + 1))"
fi
if [[ "$include_codex_logs" == "1" && "$codex_log_reclaimable_mb" -gt 0 ]]; then
  cleanup_target_count="$((cleanup_target_count + 1))"
fi

repo_reclaimable_mb="$(sum_size_mb "${cleanup_targets[@]}")"
temp_reclaimable_mb="$(sum_size_mb "${temp_cleanup_targets[@]}")"
build_cache_reclaimable_mb="$(sum_size_mb "${build_cleanup_targets[@]}")"
run_binary_cache_reclaimable_mb=0
if [[ -n "$cache_dir" && -e "$cache_dir" ]] && ! cache_dir_is_covered_by_target; then
  run_binary_cache_reclaimable_mb="$(size_mb "$cache_dir")"
fi
total_reclaimable_mb="$((repo_reclaimable_mb + temp_reclaimable_mb + build_cache_reclaimable_mb + run_binary_cache_reclaimable_mb + codex_log_reclaimable_mb))"
projected_available_disk_mb="$available_disk_mb"
if [[ "$available_disk_mb" =~ ^[0-9]+$ ]]; then
  projected_available_disk_mb="$((available_disk_mb + total_reclaimable_mb))"
fi
disk_guard_required_mb="$((min_available_disk_mb + min_disk_headroom_mb))"
reserve_shortfall_after_cleanup_mb=0
guard_shortfall_after_cleanup_mb=0
if [[ "$projected_available_disk_mb" =~ ^[0-9]+$ ]]; then
  if (( projected_available_disk_mb < min_available_disk_mb )); then
    reserve_shortfall_after_cleanup_mb="$((min_available_disk_mb - projected_available_disk_mb))"
  fi
  if (( projected_available_disk_mb < disk_guard_required_mb )); then
    guard_shortfall_after_cleanup_mb="$((disk_guard_required_mb - projected_available_disk_mb))"
  fi
fi
cleanup_can_satisfy_reserve=false
cleanup_can_satisfy_guard=false
if [[ "$safe_to_clean" == "true" && "$projected_available_disk_mb" =~ ^[0-9]+$ ]]; then
  if (( projected_available_disk_mb >= min_available_disk_mb )); then
    cleanup_can_satisfy_reserve=true
  fi
  if (( projected_available_disk_mb >= disk_guard_required_mb )); then
    cleanup_can_satisfy_guard=true
  fi
fi

recommended_action="ok"
if [[ "$safe_to_clean" != "true" ]]; then
  recommended_action="wait-active-generated-work"
elif [[ "$reserve_met" != "true" && "$cleanup_target_count" -gt 0 && "$cleanup_can_satisfy_reserve" == "true" ]]; then
  recommended_action="run-cleanup"
elif [[ "$reserve_met" != "true" && "$cleanup_target_count" -gt 0 ]]; then
  recommended_action="run-cleanup-then-free-disk-externally"
elif [[ "$reserve_met" != "true" ]]; then
  recommended_action="free-disk-externally"
elif [[ "$disk_low_headroom" == "true" && "$cleanup_target_count" -gt 0 && "$cleanup_can_satisfy_guard" == "true" ]]; then
  recommended_action="cleanup-low-disk-headroom"
elif [[ "$disk_low_headroom" == "true" && "$cleanup_target_count" -gt 0 ]]; then
  recommended_action="cleanup-then-free-disk-headroom"
elif [[ "$disk_low_headroom" == "true" ]]; then
  recommended_action="free-disk-headroom"
elif [[ "$cleanup_target_count" -gt 0 ]]; then
  recommended_action="cleanup-stale-generated-state"
fi

if [[ "$health" == "1" ]]; then
  if [[ "$json" == "1" ]]; then
    print_json_report "health" "$safe_to_clean" "$available_disk_mb" "$reserve_met" "$cache_dir" "$disk_headroom_mb" "$disk_shortfall_mb" "$disk_low_headroom" "$recommended_action"
  else
    printf 'mode=health\n'
    printf 'safe_to_clean=%s\n' "$safe_to_clean"
    printf 'recommended_action=%s\n' "$recommended_action"
    printf 'active_processes=%s\n' "$active_count"
    printf 'available_disk_mb=%s\n' "$available_disk_mb"
    printf 'required_disk_mb=%s\n' "$min_available_disk_mb"
    printf 'min_disk_headroom_mb=%s\n' "$min_disk_headroom_mb"
    printf 'disk_headroom_mb=%s\n' "$disk_headroom_mb"
    printf 'disk_shortfall_mb=%s\n' "$disk_shortfall_mb"
    printf 'disk_low_headroom=%s\n' "$disk_low_headroom"
    printf 'disk_reserve_met=%s\n' "$reserve_met"
    printf 'repo_reclaimable_mb=%s\n' "$repo_reclaimable_mb"
    printf 'temp_reclaimable_mb=%s\n' "$temp_reclaimable_mb"
    printf 'build_cache_reclaimable_mb=%s\n' "$build_cache_reclaimable_mb"
    printf 'run_binary_cache_reclaimable_mb=%s\n' "$run_binary_cache_reclaimable_mb"
    printf 'codex_log_included=%s\n' "$([[ "$include_codex_logs" == "1" ]] && printf true || printf false)"
    printf 'codex_log_path=%s\n' "$codex_log_path"
    printf 'codex_log_exists=%s\n' "$codex_log_exists"
    printf 'codex_log_size_bytes=%s\n' "$codex_log_size_bytes"
    printf 'codex_log_max_bytes=%s\n' "$codex_log_max_bytes"
    printf 'codex_log_reclaimable_mb=%s\n' "$codex_log_reclaimable_mb"
    printf 'total_reclaimable_mb=%s\n' "$total_reclaimable_mb"
    printf 'projected_available_disk_mb=%s\n' "$projected_available_disk_mb"
    printf 'disk_guard_required_mb=%s\n' "$disk_guard_required_mb"
    printf 'reserve_shortfall_after_cleanup_mb=%s\n' "$reserve_shortfall_after_cleanup_mb"
    printf 'guard_shortfall_after_cleanup_mb=%s\n' "$guard_shortfall_after_cleanup_mb"
    printf 'cleanup_can_satisfy_reserve=%s\n' "$cleanup_can_satisfy_reserve"
    printf 'cleanup_can_satisfy_guard=%s\n' "$cleanup_can_satisfy_guard"
    printf 'repo_generated_targets=%s\n' "${#cleanup_targets[@]}"
    printf 'temp_generated_targets=%s\n' "${#temp_cleanup_targets[@]}"
    printf 'build_cache_targets=%s\n' "${#build_cleanup_targets[@]}"
    if [[ -n "$cache_dir" ]]; then
      printf 'run_binary_cache=%s\n' "$cache_dir"
    fi
  fi
  exit 0
fi

if [[ -n "$active_report" ]]; then
  printf 'clasp-clean-generated-state: refusing cleanup because generated work is still running:\n' >&2
  printf '%s\n' "$active_report" | sed 's/^/  pid\tpath\tstatus\t/' >&2
  exit 1
fi

if [[ "$apply" == "0" ]]; then
  output_mode="dry-run"
else
  output_mode="apply"
fi

if [[ "$json" == "1" ]]; then
  print_json_report "$output_mode" "$safe_to_clean" "$available_disk_mb" "$reserve_met" "$cache_dir" "$disk_headroom_mb" "$disk_shortfall_mb" "$disk_low_headroom" "$recommended_action"
  if [[ "$apply" == "0" ]]; then
    exit 0
  fi
else
  printf 'mode=%s\n' "$output_mode"
fi

if [[ "$json" == "0" ]]; then
  if [[ "${#cleanup_targets[@]}" -eq 0 ]]; then
    printf 'repo_generated_targets=0\n'
  else
    printf 'repo_generated_targets=%s\n' "${#cleanup_targets[@]}"
    for target in "${cleanup_targets[@]}"; do
      if [[ "$verbose" == "1" ]]; then
        printf 'target=%s size=%s\n' "$target" "$(human_size "$target")"
      else
        printf 'target=%s\n' "$target"
      fi
    done
  fi

  if [[ "${#temp_cleanup_targets[@]}" -eq 0 ]]; then
    printf 'temp_generated_targets=0\n'
  else
    printf 'temp_generated_targets=%s\n' "${#temp_cleanup_targets[@]}"
    for target in "${temp_cleanup_targets[@]}"; do
      if [[ "$verbose" == "1" ]]; then
        printf 'temp_target=%s size=%s\n' "$target" "$(human_size "$target")"
      else
        printf 'temp_target=%s\n' "$target"
      fi
    done
  fi

  if [[ -n "$cache_dir" ]]; then
    printf 'run_binary_cache=%s\n' "$cache_dir"
  fi

  if [[ "$include_codex_logs" == "1" ]]; then
    if [[ "$verbose" == "1" ]]; then
      printf 'codex_log=%s sizeBytes=%s maxBytes=%s reclaimableMb=%s\n' "$codex_log_path" "$codex_log_size_bytes" "$codex_log_max_bytes" "$codex_log_reclaimable_mb"
    else
      printf 'codex_log=%s\n' "$codex_log_path"
    fi
  fi

  if [[ "${#build_cleanup_targets[@]}" -eq 0 ]]; then
    printf 'build_cache_targets=0\n'
  else
    printf 'build_cache_targets=%s\n' "${#build_cleanup_targets[@]}"
    for target in "${build_cleanup_targets[@]}"; do
      if [[ "$verbose" == "1" ]]; then
        printf 'build_cache_target=%s size=%s\n' "$target" "$(human_size "$target")"
      else
        printf 'build_cache_target=%s\n' "$target"
      fi
    done
  fi
fi

if [[ "$apply" == "0" ]]; then
  exit 0
fi

for target in "${cleanup_targets[@]}"; do
  rm -rf -- "$target"
done

for target in "${temp_cleanup_targets[@]}"; do
  rm -rf -- "$target"
done

for target in "${build_cleanup_targets[@]}"; do
  rm -rf -- "$target"
done

if [[ -n "$cache_dir" ]]; then
  rm -rf -- "$cache_dir"
  mkdir -p "$cache_dir"
fi

if [[ "$include_codex_logs" == "1" ]]; then
  cap_log_file_tail "$codex_log_path" "$codex_log_max_bytes"
fi

if [[ "$json" == "0" ]]; then
  printf 'cleanup=ok\n'
fi
