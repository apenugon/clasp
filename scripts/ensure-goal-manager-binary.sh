#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goal_manager_flat_source="$project_root/examples/swarm-native/GoalManager.clasp"
goal_manager_wrapper_source="$project_root/examples/swarm-native/GoalManager.wrapper.clasp"
goal_manager_split_entry_source="$project_root/examples/swarm-native/GoalManagerProgram2.split.clasp"
goal_manager_swarm_source_dir="$project_root/examples/swarm-native"

select_default_goal_manager_source() {
  if [[ -f "$goal_manager_wrapper_source" ]]; then
    printf '%s\n' "$goal_manager_wrapper_source"
  elif [[ -f "$goal_manager_flat_source" ]]; then
    printf '%s\n' "$goal_manager_flat_source"
  elif [[ -f "$goal_manager_split_entry_source" ]]; then
    printf '%s\n' "$goal_manager_split_entry_source"
  else
    printf '%s\n' "$goal_manager_wrapper_source"
  fi
}

goal_manager_source="${CLASP_GOAL_MANAGER_SOURCE:-$(select_default_goal_manager_source)}"
default_cache_parent="${XDG_CACHE_HOME:-/tmp/clasp-nix-cache}"
cache_root="${CLASP_GOAL_MANAGER_CACHE_DIR:-$default_cache_parent/goal-manager-fast}"
claspc_bin="${CLASP_GOAL_MANAGER_CLASPC_BIN:-$("$project_root/scripts/resolve-claspc.sh")}"
compile_timeout_secs="${CLASP_GOAL_MANAGER_COMPILE_TIMEOUT_SECS:-180}"
compile_attempts="${CLASP_GOAL_MANAGER_COMPILE_ATTEMPTS:-2}"
compile_managed_mode="${CLASP_GOAL_MANAGER_COMPILE_MANAGED:-auto}"
compile_memory_mb="${CLASP_GOAL_MANAGER_COMPILE_MEMORY_MB:-8192}"
compile_min_available_memory_mb="${CLASP_GOAL_MANAGER_COMPILE_MIN_AVAILABLE_MEMORY_MB:-40960}"
allow_stale_on_compile_failure="${CLASP_GOAL_MANAGER_ALLOW_STALE_ON_COMPILE_FAILURE:-1}"
allow_unmanaged_stale="${CLASP_GOAL_MANAGER_ALLOW_UNMANAGED_STALE:-0}"
stale_smoke_timeout_secs="${CLASP_GOAL_MANAGER_STALE_SMOKE_TIMEOUT_SECS:-5}"
goal_manager_native_bundle_jobs="${CLASP_NATIVE_BUNDLE_JOBS:-1}"
goal_manager_native_image_section_jobs="${CLASP_NATIVE_IMAGE_SECTION_JOBS:-1}"
goal_manager_native_image_monolithic_decl_threshold="${CLASP_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD:-999999}"
goal_manager_relaxed_build_plan_cache="${CLASP_NATIVE_RELAXED_BUILD_PLAN_CACHE:-1}"
declare -a alias_paths=()

usage() {
  cat <<'EOF' >&2
usage: ensure-goal-manager-binary.sh [--alias <path>]...

Environment:
  CLASP_GOAL_MANAGER_COMPILE_MANAGED=0       Disable managed-job memory guard around cache-miss compiles.
  CLASP_GOAL_MANAGER_COMPILE_MEMORY_MB=8192  Hard memory cap for managed cache-miss compiles.
  CLASP_GOAL_MANAGER_COMPILE_MIN_AVAILABLE_MEMORY_MB=40960
                                               Host memory reserve that stops managed compiles early.
  CLASP_GOAL_MANAGER_ALLOW_UNMANAGED_STALE=1  Permit stale fallback to executables without helper metadata after smoke validation.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alias)
      alias_paths+=("$2")
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

emit_optional_build_mode() {
  local name="$1"

  if [[ -v "$name" ]]; then
    printf 'goal-manager-build-mode\t%s\t%s\n' "$name" "${!name}"
  else
    printf 'goal-manager-build-mode\t%s\t<unset>\n' "$name"
  fi
}

emit_goal_manager_build_mode_key() {
  printf 'goal-manager-build-mode\tRUSTC\t/definitely-missing-rustc\n'
  printf 'goal-manager-build-mode\tCLASP_NATIVE_BUNDLE_JOBS\t%s\n' "$goal_manager_native_bundle_jobs"
  printf 'goal-manager-build-mode\tCLASP_NATIVE_IMAGE_SECTION_JOBS\t%s\n' "$goal_manager_native_image_section_jobs"
  printf 'goal-manager-build-mode\tCLASP_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD\t%s\n' "$goal_manager_native_image_monolithic_decl_threshold"
  emit_optional_build_mode CLASP_NATIVE_IMAGE_MONOLITHIC_BUNDLE_BYTES_THRESHOLD
  emit_optional_build_mode CLASP_NATIVE_DISABLE_EXPORT_HOST
  emit_optional_build_mode CLASP_NATIVE_DISABLE_PROMOTED_MODULE_SUMMARY_CACHE
  emit_optional_build_mode CLASP_NATIVE_DISABLE_PROMOTED_SOURCE_EXPORT_CACHE
  printf 'goal-manager-build-mode\tCLASP_NATIVE_RELAXED_BUILD_PLAN_CACHE\t%s\n' "$goal_manager_relaxed_build_plan_cache"
}

canonical_existing_path() {
  local path="$1"
  local parent
  local name

  parent="$(cd "$(dirname "$path")" && pwd -P)"
  name="$(basename "$path")"
  printf '%s/%s\n' "$parent" "$name"
}

json_escape_goal_manager_value() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

json_goal_manager_string() {
  printf '"%s"' "$(json_escape_goal_manager_value "$1")"
}

goal_manager_metadata_path() {
  printf '%s.metadata.json\n' "$1"
}

goal_manager_cache_path_id() {
  local path="$1"
  local canonical_path
  local canonical_project_root

  canonical_path="$(canonical_existing_path "$path")"
  canonical_project_root="$(canonical_existing_path "$project_root")"
  case "$canonical_path" in
    "$canonical_project_root"/*)
      printf '%s\n' "${canonical_path#"$canonical_project_root/"}"
      ;;
    *)
      printf '%s\n' "$canonical_path"
      ;;
  esac
}

emit_goal_manager_file_cache_hash() {
  local path="$1"
  local hash

  hash="$(sha256sum "$path" | awk '{print $1}')"
  printf '%s  %s\n' "$hash" "$(goal_manager_cache_path_id "$path")"
}

source_is_swarm_native_clasp() {
  local canonical_source="$1"
  local canonical_swarm_dir

  canonical_swarm_dir="$(canonical_existing_path "$goal_manager_swarm_source_dir")"
  case "$canonical_source" in
    "$canonical_swarm_dir"/*.clasp)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

emit_goal_manager_import_closure_hashes() {
  local entry_source="$1"
  local canonical_swarm_dir
  local current
  local canonical_current
  local import_name
  local import_path
  local -a queue=()
  local -a closure=()
  local -A seen=()

  canonical_swarm_dir="$(canonical_existing_path "$goal_manager_swarm_source_dir")"
  queue+=("$(canonical_existing_path "$entry_source")")

  while (( ${#queue[@]} > 0 )); do
    current="${queue[0]}"
    queue=("${queue[@]:1}")
    canonical_current="$(canonical_existing_path "$current")"
    if [[ -n "${seen[$canonical_current]:-}" ]]; then
      continue
    fi

    seen["$canonical_current"]=1
    closure+=("$canonical_current")

    while read -r import_name; do
      import_path="$canonical_swarm_dir/${import_name//./\/}.clasp"
      if [[ -f "$import_path" ]]; then
        queue+=("$import_path")
      fi
    done < <(awk '/^[[:space:]]*import[[:space:]]+[A-Za-z0-9_.]+/ { print $2 }' "$canonical_current")
  done

  for current in "${closure[@]}"; do
    emit_goal_manager_file_cache_hash "$current"
  done | sort -k2
}

emit_goal_manager_source_dependency_hashes() {
  local canonical_source

  canonical_source="$(canonical_existing_path "$goal_manager_source")"
  if source_is_swarm_native_clasp "$canonical_source"; then
    emit_goal_manager_import_closure_hashes "$canonical_source"
  else
    printf '<none>\n'
  fi
}

emit_goal_manager_promoted_native_image_hash() {
  local canonical_source
  local canonical_promoted_source
  local image_path

  canonical_source="$(canonical_existing_path "$goal_manager_source")"
  if [[ ! -f "$goal_manager_wrapper_source" ]]; then
    printf '<none>\n'
    return 0
  fi
  canonical_promoted_source="$(canonical_existing_path "$goal_manager_wrapper_source")"
  image_path="$project_root/src/stage1.goal-manager.native.image.json"
  if [[ "$canonical_source" == "$canonical_promoted_source" && -f "$image_path" ]]; then
    emit_goal_manager_file_cache_hash "$image_path"
  else
    printf '<none>\n'
  fi
}

compute_goal_manager_cache_key() {
  {
    printf 'goal-manager-source\t%s\n' "$(goal_manager_cache_path_id "$goal_manager_source")"
    printf 'goal-manager-source-content\t'
    emit_goal_manager_file_cache_hash "$goal_manager_source"
    printf 'goal-manager-source-dependencies\t'
    emit_goal_manager_source_dependency_hashes
    printf 'goal-manager-promoted-native-image\t'
    emit_goal_manager_promoted_native_image_hash
    printf 'claspc-content\t'
    sha256sum "$claspc_bin" | awk '{print $1}'
    emit_goal_manager_build_mode_key
  } | sha256sum | awk '{print $1}'
}

write_goal_manager_binary_metadata() {
  local binary_path="$1"
  local metadata_path
  local metadata_tmp
  local source_id
  local source_hash
  local dependency_hash
  local claspc_hash
  local build_mode_hash
  local created_at

  metadata_path="$(goal_manager_metadata_path "$binary_path")"
  metadata_tmp="$metadata_path.tmp.$$"
  source_id="$(goal_manager_cache_path_id "$goal_manager_source")"
  source_hash="$(sha256sum "$goal_manager_source" | awk '{print $1}')"
  dependency_hash="$(emit_goal_manager_source_dependency_hashes | sha256sum | awk '{print $1}')"
  claspc_hash="$(sha256sum "$claspc_bin" | awk '{print $1}')"
  build_mode_hash="$(emit_goal_manager_build_mode_key | sha256sum | awk '{print $1}')"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')"

  rm -f "$metadata_tmp"
  {
    printf '{\n'
    printf '  "schemaVersion": 1,\n'
    printf '  "kind": "clasp-goal-manager-binary",\n'
    printf '  "createdBy": "scripts/ensure-goal-manager-binary.sh",\n'
    printf '  "createdAt": %s,\n' "$(json_goal_manager_string "$created_at")"
    printf '  "source": %s,\n' "$(json_goal_manager_string "$source_id")"
    printf '  "sourceSha256": %s,\n' "$(json_goal_manager_string "$source_hash")"
    printf '  "sourceDependencySha256": %s,\n' "$(json_goal_manager_string "$dependency_hash")"
    printf '  "claspcSha256": %s,\n' "$(json_goal_manager_string "$claspc_hash")"
    printf '  "buildModeSha256": %s,\n' "$(json_goal_manager_string "$build_mode_hash")"
    printf '  "cacheKey": %s\n' "$(json_goal_manager_string "$cache_key")"
    printf '}\n'
  } >"$metadata_tmp"
  mv "$metadata_tmp" "$metadata_path"
}

normalize_goal_manager_compile_guards() {
  if ! [[ "$compile_timeout_secs" =~ ^[0-9]+$ ]]; then
    compile_timeout_secs=0
  fi
  if ! [[ "$compile_attempts" =~ ^[0-9]+$ ]] || (( compile_attempts < 1 )); then
    compile_attempts=4
  fi
  if ! [[ "$compile_memory_mb" =~ ^[0-9]+$ ]]; then
    compile_memory_mb=8192
  fi
  if ! [[ "$compile_min_available_memory_mb" =~ ^[0-9]+$ ]]; then
    compile_min_available_memory_mb=40960
  fi
}

goal_manager_compile_managed_enabled() {
  case "$compile_managed_mode" in
    0|false|FALSE|False|no|NO|No|off|OFF|Off|never|NEVER|Never)
      return 1
      ;;
  esac

  [[ -x "$project_root/scripts/run-managed-job.sh" ]] || return 1
  return 0
}

run_goal_manager_compile_direct() {
  local output_tmp="$1"

  if (( compile_timeout_secs > 0 )); then
    timeout --kill-after=5s "$compile_timeout_secs" \
      env \
        RUSTC=/definitely-missing-rustc \
        CLASP_PROJECT_ROOT="$project_root" \
        CLASP_NATIVE_BUNDLE_JOBS="$goal_manager_native_bundle_jobs" \
        CLASP_NATIVE_IMAGE_SECTION_JOBS="$goal_manager_native_image_section_jobs" \
        CLASP_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD="$goal_manager_native_image_monolithic_decl_threshold" \
        CLASP_NATIVE_RELAXED_BUILD_PLAN_CACHE="$goal_manager_relaxed_build_plan_cache" \
        "$claspc_bin" compile "$goal_manager_source" -o "$output_tmp"
  else
    env \
      RUSTC=/definitely-missing-rustc \
      CLASP_PROJECT_ROOT="$project_root" \
      CLASP_NATIVE_BUNDLE_JOBS="$goal_manager_native_bundle_jobs" \
      CLASP_NATIVE_IMAGE_SECTION_JOBS="$goal_manager_native_image_section_jobs" \
      CLASP_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD="$goal_manager_native_image_monolithic_decl_threshold" \
      CLASP_NATIVE_RELAXED_BUILD_PLAN_CACHE="$goal_manager_relaxed_build_plan_cache" \
      "$claspc_bin" compile "$goal_manager_source" -o "$output_tmp"
  fi
}

run_goal_manager_compile_managed() {
  local output_tmp="$1"
  local job_dir=""
  local launch_status=0
  local status=""
  local exit_status=1
  local -a managed_args=("$project_root/scripts/run-managed-job.sh" --jobs-root "$cache_root/compile-jobs")
  local -a compile_args=(
    env
    RUSTC=/definitely-missing-rustc
    CLASP_PROJECT_ROOT="$project_root"
    CLASP_NATIVE_BUNDLE_JOBS="$goal_manager_native_bundle_jobs"
    CLASP_NATIVE_IMAGE_SECTION_JOBS="$goal_manager_native_image_section_jobs"
    CLASP_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD="$goal_manager_native_image_monolithic_decl_threshold"
    CLASP_NATIVE_RELAXED_BUILD_PLAN_CACHE="$goal_manager_relaxed_build_plan_cache"
    "$claspc_bin" compile "$goal_manager_source" -o "$output_tmp"
  )

  if (( compile_memory_mb > 0 )); then
    managed_args+=(--memory-mb "$compile_memory_mb")
  fi
  if (( compile_min_available_memory_mb > 0 )); then
    managed_args+=(--min-available-memory-mb "$compile_min_available_memory_mb")
  fi

  if (( compile_timeout_secs > 0 )); then
    job_dir="$(
      "${managed_args[@]}" \
        -- timeout --kill-after=5s "$compile_timeout_secs" "${compile_args[@]}"
    )" || launch_status=$?
    if (( launch_status != 0 )); then
      return "$launch_status"
    fi
  else
    job_dir="$("${managed_args[@]}" -- "${compile_args[@]}")" || launch_status=$?
    if (( launch_status != 0 )); then
      return "$launch_status"
    fi
  fi

  while true; do
    status="$(sed -n '1p' "$job_dir/status" 2>/dev/null || printf 'missing')"
    case "$status" in
      completed|failed|stopped)
        break
        ;;
    esac
    sleep 0.2
  done

  if [[ -f "$job_dir/stdout.log" ]]; then
    cat "$job_dir/stdout.log"
  fi
  if [[ -f "$job_dir/stderr.log" ]]; then
    cat "$job_dir/stderr.log" >&2
  fi
  if [[ -f "$job_dir/memory-exceeded" ]]; then
    printf 'goal manager compile memory guard tripped:\n' >&2
    sed 's/^/  /' "$job_dir/memory-exceeded" >&2 || true
  fi

  if [[ -f "$job_dir/exit-status" ]]; then
    exit_status="$(tr -d '[:space:]' <"$job_dir/exit-status")"
  elif [[ "$status" == "completed" ]]; then
    exit_status=0
  fi
  if ! [[ "$exit_status" =~ ^[0-9]+$ ]]; then
    exit_status=1
  fi

  return "$exit_status"
}

run_goal_manager_compile_attempt() {
  local output_tmp="$1"

  if goal_manager_compile_managed_enabled; then
    run_goal_manager_compile_managed "$output_tmp"
  else
    run_goal_manager_compile_direct "$output_tmp"
  fi
}

compile_goal_manager_binary() {
  local output_path="$1"
  local output_tmp="$output_path.tmp.$$"
  local compile_status=0
  local attempt=1

  normalize_goal_manager_compile_guards

  rm -f "$output_tmp"

  while (( attempt <= compile_attempts )); do
    compile_status=0
    run_goal_manager_compile_attempt "$output_tmp" || compile_status=$?

    if (( compile_status == 0 )); then
      break
    fi

    rm -f "$output_tmp"
    if ! (( compile_status == 124 || compile_status == 137 )) || (( attempt >= compile_attempts )); then
      break
    fi
    printf 'goal manager compile timed out after %ss on attempt %s/%s; retrying with warmed caches: %s\n' \
      "$compile_timeout_secs" "$attempt" "$compile_attempts" "$goal_manager_source" >&2
    attempt=$((attempt + 1))
  done

  if (( compile_status != 0 )); then
    rm -f "$output_tmp"
    if (( compile_status == 124 || compile_status == 137 )); then
      printf 'goal manager compile timed out after %ss across %s attempt(s): %s\n' "$compile_timeout_secs" "$compile_attempts" "$goal_manager_source" >&2
    else
      printf 'goal manager compile failed with exit %s: %s\n' "$compile_status" "$goal_manager_source" >&2
    fi
    return "$compile_status"
  fi

  chmod +x "$output_tmp"
  mv "$output_tmp" "$output_path"
  if ! write_goal_manager_binary_metadata "$output_path"; then
    rm -f "$output_path" "$(goal_manager_metadata_path "$output_path")"
    return 1
  fi
}

sync_goal_manager_alias_metadata() {
  local source_path="$1"
  local alias_path="$2"
  local source_metadata
  local alias_metadata
  local alias_metadata_tmp

  source_metadata="$(goal_manager_metadata_path "$source_path")"
  alias_metadata="$(goal_manager_metadata_path "$alias_path")"
  if [[ "$source_metadata" == "$alias_metadata" ]]; then
    return 0
  fi

  if [[ -f "$source_metadata" ]]; then
    if [[ -f "$alias_metadata" ]] && cmp -s "$source_metadata" "$alias_metadata"; then
      return 0
    fi
    alias_metadata_tmp="$alias_metadata.tmp.$$"
    rm -f "$alias_metadata_tmp"
    cp "$source_metadata" "$alias_metadata_tmp"
    mv "$alias_metadata_tmp" "$alias_metadata"
  else
    rm -f "$alias_metadata"
  fi
}

sync_goal_manager_alias() {
  local source_path="$1"
  local alias_path="$2"
  local alias_tmp="$alias_path.tmp.$$"

  mkdir -p "$(dirname "$alias_path")"
  if [[ -x "$alias_path" ]] && cmp -s "$source_path" "$alias_path"; then
    sync_goal_manager_alias_metadata "$source_path" "$alias_path"
    return 0
  fi

  rm -f "$alias_tmp"
  cp "$source_path" "$alias_tmp"
  chmod +x "$alias_tmp"
  mv "$alias_tmp" "$alias_path"
  sync_goal_manager_alias_metadata "$source_path" "$alias_path"
}

emit_stale_goal_manager_candidates() {
  local candidate
  local -A seen=()

  for candidate in "${alias_paths[@]}"; do
    if [[ -x "$candidate" && -z "${seen[$candidate]:-}" ]]; then
      seen["$candidate"]=1
      printf '%s\n' "$candidate"
    fi
  done

  while IFS= read -r candidate; do
    if [[ -n "$candidate" && "$candidate" != "$goal_manager_binary" && -x "$candidate" && -z "${seen[$candidate]:-}" ]]; then
      seen["$candidate"]=1
      printf '%s\n' "$candidate"
    fi
  done < <(find "$cache_root" -mindepth 2 -maxdepth 2 -type f -name swarm-goal-manager -printf '%T@ %p\n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
}

validate_goal_manager_binary_metadata() {
  local candidate="$1"
  local candidate_label="$2"
  local metadata_path
  local expected_source_json

  metadata_path="$(goal_manager_metadata_path "$candidate")"
  expected_source_json="$(json_goal_manager_string "$(goal_manager_cache_path_id "$goal_manager_source")")"
  if [[ ! -f "$metadata_path" ]]; then
    if [[ "$allow_unmanaged_stale" == "1" ]]; then
      printf '%s goal manager candidate has no helper metadata; accepting only because CLASP_GOAL_MANAGER_ALLOW_UNMANAGED_STALE=1: %s\n' "$candidate_label" "$candidate" >&2
    else
      printf '%s goal manager candidate missing helper metadata: %s\n' "$candidate_label" "$candidate" >&2
      return 1
    fi
  elif ! grep -F '"kind": "clasp-goal-manager-binary"' "$metadata_path" >/dev/null 2>&1; then
    printf '%s goal manager candidate has invalid helper metadata: %s\n' "$candidate_label" "$candidate" >&2
    return 1
  elif ! grep -F "\"source\": $expected_source_json" "$metadata_path" >/dev/null 2>&1; then
    printf '%s goal manager candidate metadata source mismatch: %s\n' "$candidate_label" "$candidate" >&2
    return 1
  fi

  return 0
}

smoke_goal_manager_binary() {
  local candidate="$1"
  local candidate_label="$2"
  local smoke_root
  local smoke_output
  local smoke_status=0

  if ! [[ "$stale_smoke_timeout_secs" =~ ^[0-9]+$ ]]; then
    stale_smoke_timeout_secs=5
  fi

  smoke_root="$(mktemp -d "${TMPDIR:-/tmp}/clasp-goal-manager-stale-smoke.XXXXXX")"
  if (( stale_smoke_timeout_secs > 0 )); then
    smoke_output="$(
      timeout --kill-after=2s "$stale_smoke_timeout_secs" \
        env CLASP_MANAGER_COMMAND=status CLASP_LOOP_COMMAND=status "$candidate" "$smoke_root" 2>&1
    )" || smoke_status=$?
  else
    smoke_output="$(
      env CLASP_MANAGER_COMMAND=status CLASP_LOOP_COMMAND=status "$candidate" "$smoke_root" 2>&1
    )" || smoke_status=$?
  fi
  rm -rf "$smoke_root"

  if (( smoke_status != 0 )); then
    printf '%s goal manager candidate failed status smoke with exit %s: %s\n' "$candidate_label" "$smoke_status" "$candidate" >&2
    return 1
  fi
  if [[ "$smoke_output" == *"runtime failed to execute native compiler export main"* ]]; then
    printf '%s goal manager candidate failed status smoke with native export error: %s\n' "$candidate_label" "$candidate" >&2
    return 1
  fi
  if [[ "$smoke_output" != *'"state"'* || "$smoke_output" != *'"phase"'* ]]; then
    printf '%s goal manager candidate failed status smoke with unexpected output: %s\n' "$candidate_label" "$candidate" >&2
    return 1
  fi

  return 0
}

validate_stale_goal_manager_binary() {
  local candidate="$1"

  validate_goal_manager_binary_metadata "$candidate" "stale" &&
    smoke_goal_manager_binary "$candidate" "stale"
}

validate_cached_goal_manager_binary() {
  local candidate="$1"

  validate_goal_manager_binary_metadata "$candidate" "cached" &&
    smoke_goal_manager_binary "$candidate" "cached"
}

find_stale_goal_manager_binary() {
  local candidate

  while IFS= read -r candidate; do
    if validate_stale_goal_manager_binary "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(emit_stale_goal_manager_candidates)

  return 1
}

use_stale_goal_manager_binary() {
  local fallback_binary

  if [[ "$allow_stale_on_compile_failure" == "0" ]]; then
    return 1
  fi

  fallback_binary="$(find_stale_goal_manager_binary || true)"
  if [[ -z "$fallback_binary" ]]; then
    return 1
  fi

  printf 'goal manager compile failed; using validated stale goal manager binary: %s\n' "$fallback_binary" >&2
  goal_manager_binary="$fallback_binary"
}

mkdir -p "$cache_root"
cache_key="$(compute_goal_manager_cache_key)"
goal_manager_binary="$cache_root/$cache_key/swarm-goal-manager"
mkdir -p "$(dirname "$goal_manager_binary")"
compile_lock="$(dirname "$goal_manager_binary")/compile.lock"

if [[ "${CLASP_GOAL_MANAGER_FORCE_RECOMPILE:-0}" == "1" ]]; then
  rm -f "$goal_manager_binary"
fi

if [[ -x "$goal_manager_binary" ]] && ! validate_cached_goal_manager_binary "$goal_manager_binary"; then
  rm -f "$goal_manager_binary" "$(goal_manager_metadata_path "$goal_manager_binary")"
fi

if [[ ! -x "$goal_manager_binary" ]]; then
  compile_status=0
  (
    flock 9
    if [[ "${CLASP_GOAL_MANAGER_FORCE_RECOMPILE:-0}" == "1" ]]; then
      rm -f "$goal_manager_binary"
    fi
    if [[ ! -x "$goal_manager_binary" ]]; then
      compile_goal_manager_binary "$goal_manager_binary"
    fi
  ) 9>"$compile_lock" || compile_status=$?
  if (( compile_status != 0 )) && [[ ! -x "$goal_manager_binary" ]]; then
    if ! use_stale_goal_manager_binary; then
      exit "$compile_status"
    fi
  fi
fi

for alias_path in "${alias_paths[@]}"; do
  sync_goal_manager_alias "$goal_manager_binary" "$alias_path"
done

printf '%s\n' "$goal_manager_binary"
