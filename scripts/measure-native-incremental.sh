#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
time_bin="$(which time 2>/dev/null || true)"
probe_root="$(mktemp -d)"
scenario="native-cli-body-change"
assert_mode=0
report_path=""
max_duration_args=()

cleanup() {
  rm -rf "$probe_root"
}

trap cleanup EXIT

usage() {
  printf '%s\n' \
    'usage: bash scripts/measure-native-incremental.sh [--scenario <native-cli-body-change|selfhost-body-change>] [--assert] [--report <path>] [--max-duration <timing>=<seconds>]' >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)
      scenario="${2:-}"
      if [[ -z "$scenario" ]]; then
        usage
        exit 1
      fi
      shift 2
      ;;
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
    --max-duration)
      if [[ -z "${2:-}" ]]; then
        usage
        exit 1
      fi
      max_duration_args+=(--max-duration "$2")
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

case "$scenario" in
  native-cli-body-change|selfhost-body-change)
    ;;
  *)
    printf 'unknown incremental measurement scenario: %s\n' "$scenario" >&2
    usage
    exit 1
    ;;
esac

append_guard_options() {
  if [[ -n "$report_path" ]]; then
    guard_args+=(--report "$report_path")
  fi

  if [[ "$assert_mode" == "1" ]]; then
    guard_args+=(--assert)
  fi

  if [[ "${#max_duration_args[@]}" -gt 0 ]]; then
    guard_args+=("${max_duration_args[@]}")
  fi
}

write_native_cli_probe_project() {
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

write_selfhost_probe_project() {
  local project_dir="$1"
  local entry_path="$2"

  mkdir -p "$project_dir"

  cat >"$entry_path" <<'EOF'
module Main

import Helper

main : Str
main = helper "input"
EOF

  cat >"$project_dir/Helper.clasp" <<'EOF'
module Helper

helper : Str -> Str
helper value = "hello"
EOF
}

run_native_cli_body_change() {
  local native_project_dir="$probe_root/native-image-project"
  local native_project_path="$native_project_dir/Main.clasp"
  local native_cache_root="$probe_root/native-cache"
  local check_project_dir="$probe_root/check-project"
  local check_project_path="$check_project_dir/Main.clasp"
  local check_cache_root="$probe_root/check-cache"

  write_native_cli_probe_project "$native_project_dir" "$native_project_path"
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

  write_native_cli_probe_project "$check_project_dir" "$check_project_path"
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
  append_guard_options
  node "${guard_args[@]}"
}

run_selfhost_body_change() {
  local selfhost_project_dir="$probe_root/selfhost-project"
  local selfhost_project_path="$selfhost_project_dir/Main.clasp"
  local selfhost_cache_root="$probe_root/selfhost-cache"

  write_selfhost_probe_project "$selfhost_project_dir" "$selfhost_project_path"
  mkdir -p "$selfhost_cache_root"

  "$time_bin" -p -o "$probe_root/selfhost.check.cold.time" \
    env XDG_CACHE_HOME="$selfhost_cache_root" CLASP_NATIVE_TRACE_CACHE=1 CLASP_NATIVE_TRACE_HOST=1 CLASP_NATIVE_TRACE_TIMING=1 \
    "$claspc_bin" --json check "$selfhost_project_path" \
    >"$probe_root/selfhost.check.cold.json" 2>"$probe_root/selfhost.check.cold.log"
  "$time_bin" -p -o "$probe_root/selfhost.image.cold.time" \
    env XDG_CACHE_HOME="$selfhost_cache_root" CLASP_NATIVE_TRACE_CACHE=1 CLASP_NATIVE_TRACE_HOST=1 CLASP_NATIVE_TRACE_TIMING=1 CLASPC_BIN="$claspc_bin" \
    bash "$project_root/src/scripts/run-native-tool.sh" \
    "$project_root/src/embedded.compiler.native.image.json" \
    nativeImageProjectText \
    "--project-entry=$selfhost_project_path" \
    "$probe_root/selfhost.image.cold.native.image.json" >"$probe_root/selfhost.image.cold.log" 2>&1

  "$time_bin" -p -o "$probe_root/selfhost.check.warm.time" \
    env XDG_CACHE_HOME="$selfhost_cache_root" CLASP_NATIVE_TRACE_CACHE=1 CLASP_NATIVE_TRACE_HOST=1 CLASP_NATIVE_TRACE_TIMING=1 \
    "$claspc_bin" --json check "$selfhost_project_path" \
    >"$probe_root/selfhost.check.warm.json" 2>"$probe_root/selfhost.check.warm.log"
  "$time_bin" -p -o "$probe_root/selfhost.image.warm.time" \
    env XDG_CACHE_HOME="$selfhost_cache_root" CLASP_NATIVE_TRACE_CACHE=1 CLASP_NATIVE_TRACE_HOST=1 CLASP_NATIVE_TRACE_TIMING=1 CLASPC_BIN="$claspc_bin" \
    bash "$project_root/src/scripts/run-native-tool.sh" \
    "$project_root/src/embedded.compiler.native.image.json" \
    nativeImageProjectText \
    "--project-entry=$selfhost_project_path" \
    "$probe_root/selfhost.image.warm.native.image.json" >"$probe_root/selfhost.image.warm.log" 2>&1

  sed -i 's/"hello"/"hullo"/' "$selfhost_project_dir/Helper.clasp"

  "$time_bin" -p -o "$probe_root/selfhost.check.body-change.time" \
    env XDG_CACHE_HOME="$selfhost_cache_root" CLASP_NATIVE_TRACE_CACHE=1 CLASP_NATIVE_TRACE_HOST=1 CLASP_NATIVE_TRACE_TIMING=1 \
    "$claspc_bin" --json check "$selfhost_project_path" \
    >"$probe_root/selfhost.check.body-change.json" 2>"$probe_root/selfhost.check.body-change.log"
  "$time_bin" -p -o "$probe_root/selfhost.image.body-change.time" \
    env XDG_CACHE_HOME="$selfhost_cache_root" CLASP_NATIVE_TRACE_CACHE=1 CLASP_NATIVE_TRACE_HOST=1 CLASP_NATIVE_TRACE_TIMING=1 CLASPC_BIN="$claspc_bin" \
    bash "$project_root/src/scripts/run-native-tool.sh" \
    "$project_root/src/embedded.compiler.native.image.json" \
    nativeImageProjectText \
    "--project-entry=$selfhost_project_path" \
    "$probe_root/selfhost.image.body-change.native.image.json" >"$probe_root/selfhost.image.body-change.log" 2>&1

  guard_args=(
    "$project_root/scripts/native-incremental-guard.mjs"
    selfhost-body-change
    --check-log "$probe_root/selfhost.check.body-change.log"
    --image-log "$probe_root/selfhost.image.body-change.log"
    --time "checkCold=$probe_root/selfhost.check.cold.time"
    --time "imageCold=$probe_root/selfhost.image.cold.time"
    --time "checkWarm=$probe_root/selfhost.check.warm.time"
    --time "imageWarm=$probe_root/selfhost.image.warm.time"
    --time "checkBodyChange=$probe_root/selfhost.check.body-change.time"
    --time "imageBodyChange=$probe_root/selfhost.image.body-change.time"
  )
  append_guard_options
  node "${guard_args[@]}"
}

case "$scenario" in
  native-cli-body-change)
    run_native_cli_body_change
    ;;
  selfhost-body-change)
    run_selfhost_body_change
    ;;
esac
