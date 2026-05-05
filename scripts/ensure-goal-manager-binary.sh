#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goal_manager_source="${CLASP_GOAL_MANAGER_SOURCE:-$project_root/examples/swarm-native/GoalManager.wrapper.clasp}"
cache_root="${CLASP_GOAL_MANAGER_CACHE_DIR:-/tmp/clasp-nix-cache/goal-manager-fast}"
claspc_bin="${CLASP_GOAL_MANAGER_CLASPC_BIN:-$("$project_root/scripts/resolve-claspc.sh")}"
compile_timeout_secs="${CLASP_GOAL_MANAGER_COMPILE_TIMEOUT_SECS:-0}"
compile_attempts="${CLASP_GOAL_MANAGER_COMPILE_ATTEMPTS:-4}"
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

compute_goal_manager_cache_key() {
  {
    printf 'claspc-content\t'
    sha256sum "$claspc_bin"
    find \
      "$project_root/examples/swarm-native" \
      "$project_root/src" \
      "$project_root/runtime" \
      -type f \
      \( -name '*.clasp' -o -name '*.rs' -o -name 'Cargo.toml' \) \
      ! -path '*/target/*' \
      -print0 \
      | sort -z \
      | xargs -0 sha256sum
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
          CLASP_NATIVE_BUNDLE_JOBS="${CLASP_NATIVE_BUNDLE_JOBS:-8}" \
          CLASP_NATIVE_IMAGE_SECTION_JOBS="${CLASP_NATIVE_IMAGE_SECTION_JOBS:-8}" \
          "$claspc_bin" compile "$goal_manager_source" -o "$output_tmp" \
        || compile_status=$?
    else
      env \
        RUSTC=/definitely-missing-rustc \
        CLASP_NATIVE_BUNDLE_JOBS="${CLASP_NATIVE_BUNDLE_JOBS:-8}" \
        CLASP_NATIVE_IMAGE_SECTION_JOBS="${CLASP_NATIVE_IMAGE_SECTION_JOBS:-8}" \
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
  ) 9>"$cache_root/compile.lock"
fi

for alias_path in "${alias_paths[@]}"; do
  sync_goal_manager_alias "$goal_manager_binary" "$alias_path"
done

printf '%s\n' "$goal_manager_binary"
