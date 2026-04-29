#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
time_bin="$(which time 2>/dev/null || true)"
probe_root="$(mktemp -d)"
native_project_dir="$probe_root/native-image-project"
native_project_path="$native_project_dir/Main.clasp"
native_cache_root="$probe_root/native-cache"
check_project_dir="$probe_root/check-project"
check_project_path="$check_project_dir/Main.clasp"
check_cache_root="$probe_root/check-cache"
assert_mode=0
report_path=""

cleanup() {
  rm -rf "$probe_root"
}

trap cleanup EXIT

usage() {
  printf '%s\n' \
    'usage: bash scripts/measure-native-incremental.sh [--assert] [--report <path>]' >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --assert)
      assert_mode=1
      shift
      ;;
    --report)
      report_path="${2:-}"
      if [[ -z "$report_path" ]]; then
        usage
        exit 1
      fi
      shift 2
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ ! -x "$claspc_bin" ]]; then
  printf 'missing native claspc binary at %s\n' "$claspc_bin" >&2
  exit 1
fi

if [[ -z "$time_bin" || ! -x "$time_bin" ]]; then
  printf 'missing time binary\n' >&2
  exit 1
fi

write_probe_project() {
  local project_dir="$1"
  local entry_path="$2"

  mkdir -p "$project_dir/Shared"

  cat >"$entry_path" <<'EOF'
module Main

import Shared.User
import Shared.Render

main : Str
main = renderUser defaultUser
EOF

  cat >"$project_dir/Shared/User.clasp" <<'EOF'
module Shared.User

record User = { name : Str }

defaultUser : User
defaultUser = User { name = "planner" }
EOF

  cat >"$project_dir/Shared/Render.clasp" <<'EOF'
module Shared.Render

import Shared.User

renderUser : User -> Str
renderUser user = user.name
EOF
}

write_probe_project "$native_project_dir" "$native_project_path"
mkdir -p "$native_cache_root"
"$time_bin" -p -o "$probe_root/native-image.first.time" \
  env XDG_CACHE_HOME="$native_cache_root" CLASP_NATIVE_TRACE_CACHE=1 \
  "$claspc_bin" native-image "$native_project_path" -o "$probe_root/native-image.first.native.image.json" \
  >/dev/null 2>"$probe_root/native-image.first.log"
sed -i 's/planner/operator/' "$native_project_dir/Shared/User.clasp"
"$time_bin" -p -o "$probe_root/native-image.second.time" \
  env XDG_CACHE_HOME="$native_cache_root" CLASP_NATIVE_TRACE_CACHE=1 \
  "$claspc_bin" native-image "$native_project_path" -o "$probe_root/native-image.second.native.image.json" \
  >/dev/null 2>"$probe_root/native-image.second.log"

write_probe_project "$check_project_dir" "$check_project_path"
mkdir -p "$check_cache_root"
"$time_bin" -p -o "$probe_root/check.first.time" \
  env XDG_CACHE_HOME="$check_cache_root" CLASP_NATIVE_TRACE_CACHE=1 \
  "$claspc_bin" --json check "$check_project_path" \
  >"$probe_root/check.first.json" 2>"$probe_root/check.first.log"
sed -i 's/planner/operator/' "$check_project_dir/Shared/User.clasp"
"$time_bin" -p -o "$probe_root/check.second.time" \
  env XDG_CACHE_HOME="$check_cache_root" CLASP_NATIVE_TRACE_CACHE=1 \
  "$claspc_bin" --json check "$check_project_path" \
  >"$probe_root/check.second.json" 2>"$probe_root/check.second.log"

guard_args=(
  "$project_root/scripts/native-incremental-guard.mjs"
  native-cli-body-change
  --native-log "$probe_root/native-image.second.log"
  --check-log "$probe_root/check.second.log"
  --time "nativeImageCold=$probe_root/native-image.first.time"
  --time "nativeImageBodyChange=$probe_root/native-image.second.time"
  --time "checkCold=$probe_root/check.first.time"
  --time "checkBodyChange=$probe_root/check.second.time"
)

if [[ -n "$report_path" ]]; then
  guard_args+=(--report "$report_path")
fi

if [[ "$assert_mode" == "1" ]]; then
  guard_args+=(--assert)
fi

node "${guard_args[@]}"
