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
  elif [[ -f "$goal_manager_split_entry_source" ]]; then
    printf '%s\n' "$goal_manager_split_entry_source"
  else
    printf '%s\n' "$goal_manager_flat_source"
  fi
}

goal_manager_source="${CLASP_GOAL_MANAGER_SOURCE:-$(select_default_goal_manager_source)}"
default_cache_parent="${XDG_CACHE_HOME:-/tmp/clasp-nix-cache}"
cache_root="${CLASP_GOAL_MANAGER_CACHE_DIR:-$default_cache_parent/goal-manager-fast}"
claspc_bin="${CLASP_GOAL_MANAGER_CLASPC_BIN:-$("$project_root/scripts/resolve-claspc.sh")}"
compile_timeout_secs="${CLASP_GOAL_MANAGER_COMPILE_TIMEOUT_SECS:-0}"
compile_attempts="${CLASP_GOAL_MANAGER_COMPILE_ATTEMPTS:-4}"
goal_manager_native_bundle_jobs="${CLASP_NATIVE_BUNDLE_JOBS:-8}"
goal_manager_native_image_section_jobs="${CLASP_NATIVE_IMAGE_SECTION_JOBS:-8}"
goal_manager_native_image_monolithic_decl_threshold="${CLASP_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD:-999999}"
declare -a alias_paths=()

usage() {
  cat <<'EOF' >&2
usage: ensure-goal-manager-binary.sh [--alias <path>]...
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
}

canonical_existing_path() {
  local path="$1"
  local parent
  local name

  parent="$(cd "$(dirname "$path")" && pwd -P)"
  name="$(basename "$path")"
  printf '%s/%s\n' "$parent" "$name"
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

  printf '%s\0' "${closure[@]}" | sort -z | xargs -0 sha256sum
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

compute_goal_manager_cache_key() {
  {
    printf 'goal-manager-source\t%s\n' "$goal_manager_source"
    printf 'goal-manager-source-content\t'
    sha256sum "$goal_manager_source"
    printf 'goal-manager-source-dependencies\t'
    emit_goal_manager_source_dependency_hashes
    printf 'claspc-content\t'
    sha256sum "$claspc_bin"
    emit_goal_manager_build_mode_key
  } | sha256sum | awk '{print $1}'
}

compile_goal_manager_binary() {
  local output_path="$1"
  local output_tmp="$output_path.tmp.$$"
  local compile_status=0
  local attempt=1

  if ! [[ "$compile_timeout_secs" =~ ^[0-9]+$ ]]; then
    compile_timeout_secs=0
  fi
  if ! [[ "$compile_attempts" =~ ^[0-9]+$ ]] || (( compile_attempts < 1 )); then
    compile_attempts=4
  fi

  rm -f "$output_tmp"

  while (( attempt <= compile_attempts )); do
    compile_status=0
    if (( compile_timeout_secs > 0 )); then
      timeout --kill-after=5s "$compile_timeout_secs" \
        env \
          RUSTC=/definitely-missing-rustc \
          CLASP_NATIVE_BUNDLE_JOBS="$goal_manager_native_bundle_jobs" \
          CLASP_NATIVE_IMAGE_SECTION_JOBS="$goal_manager_native_image_section_jobs" \
          CLASP_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD="$goal_manager_native_image_monolithic_decl_threshold" \
          "$claspc_bin" compile "$goal_manager_source" -o "$output_tmp" \
        || compile_status=$?
    else
      env \
        RUSTC=/definitely-missing-rustc \
        CLASP_NATIVE_BUNDLE_JOBS="$goal_manager_native_bundle_jobs" \
        CLASP_NATIVE_IMAGE_SECTION_JOBS="$goal_manager_native_image_section_jobs" \
        CLASP_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD="$goal_manager_native_image_monolithic_decl_threshold" \
        "$claspc_bin" compile "$goal_manager_source" -o "$output_tmp" \
        || compile_status=$?
    fi

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
}

sync_goal_manager_alias() {
  local source_path="$1"
  local alias_path="$2"
  local alias_tmp="$alias_path.tmp.$$"

  mkdir -p "$(dirname "$alias_path")"
  if [[ -x "$alias_path" ]] && cmp -s "$source_path" "$alias_path"; then
    return 0
  fi

  rm -f "$alias_tmp"
  cp "$source_path" "$alias_tmp"
  chmod +x "$alias_tmp"
  mv "$alias_tmp" "$alias_path"
}

mkdir -p "$cache_root"
cache_key="$(compute_goal_manager_cache_key)"
goal_manager_binary="$cache_root/$cache_key/swarm-goal-manager"
mkdir -p "$(dirname "$goal_manager_binary")"
compile_lock="$(dirname "$goal_manager_binary")/compile.lock"

if [[ "${CLASP_GOAL_MANAGER_FORCE_RECOMPILE:-0}" == "1" ]]; then
  rm -f "$goal_manager_binary"
fi

if [[ ! -x "$goal_manager_binary" ]]; then
  (
    flock 9
    if [[ "${CLASP_GOAL_MANAGER_FORCE_RECOMPILE:-0}" == "1" ]]; then
      rm -f "$goal_manager_binary"
    fi
    if [[ ! -x "$goal_manager_binary" ]]; then
      compile_goal_manager_binary "$goal_manager_binary"
    fi
  ) 9>"$compile_lock"
fi

for alias_path in "${alias_paths[@]}"; do
  sync_goal_manager_alias "$goal_manager_binary" "$alias_path"
done

printf '%s\n' "$goal_manager_binary"
