#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goal_manager_source="$project_root/examples/swarm-native/GoalManager.clasp"
cache_root="${CLASP_GOAL_MANAGER_CACHE_DIR:-$project_root/.clasp-loops/.cache/goal-manager-fast}"
claspc_bin="${CLASP_GOAL_MANAGER_CLASPC_BIN:-$("$project_root/scripts/resolve-claspc.sh")}"
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
    printf 'claspc\t'
    stat -c '%Y:%s:%n' "$claspc_bin"
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

  rm -f "$output_tmp"
  env RUSTC=/definitely-missing-rustc "$claspc_bin" compile "$goal_manager_source" -o "$output_tmp"
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
