#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
time_bin="$(which time 2>/dev/null || true)"
if [[ -n "${CLASP_NATIVE_INCREMENTAL_PROBE_ROOT:-}" ]]; then
  probe_root="$CLASP_NATIVE_INCREMENTAL_PROBE_ROOT"
  probe_root_is_temp=0
  mkdir -p "$probe_root"
else
  probe_root="$(mktemp -d)"
  probe_root_is_temp=1
fi
shared_cache_root="${CLASP_NATIVE_INCREMENTAL_SHARED_CACHE_HOME:-$probe_root}"
probe_suffix="${CLASP_NATIVE_INCREMENTAL_PROBE_SUFFIX:-}"
scenario="native-cli-body-change"
assert_mode=0
report_path=""
max_duration_args=()

cleanup() {
  if [[ "$probe_root_is_temp" == "1" ]]; then
    rm -rf "$probe_root"
  fi
}

trap cleanup EXIT

usage() {
  printf '%s\n' \
    'usage: bash scripts/measure-native-incremental.sh [--scenario <native-cli-body-change|selfhost-body-change|selfhost-compiler-module-body-change>] [--assert] [--report <path>] [--max-duration <timing>=<seconds>]' \
    '       set CLASP_NATIVE_INCREMENTAL_REUSE_WARMUP=1 to reuse the selfhost cold warmup cache when available' \
    '       set CLASP_NATIVE_INCREMENTAL_COMPILER_MODULE_IMAGE_PROBE=1 to include the expensive full compiler native-image diagnostic' >&2
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
  native-cli-body-change|selfhost-body-change|selfhost-compiler-module-body-change)
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

  cat >"$project_dir/Helper.clasp" <<EOF
module Helper

helper : Str -> Str
helper value = "hello$probe_suffix"
EOF
}

copy_compiler_probe_project() {
  local project_dir="$1"
  local source_path=""
  local relative_path=""

  mkdir -p "$project_dir"
  project_dir="$(cd "$project_dir" && pwd -P)"
  (
    cd "$project_root/src"
    find . -type f -name '*.clasp' -print0 |
      while IFS= read -r -d '' source_path; do
        relative_path="${source_path#./}"
        mkdir -p "$project_dir/$(dirname "$relative_path")"
        cp "$source_path" "$project_dir/$relative_path"
      done
  )
}

edit_compiler_probe_module_body() {
  local project_dir="$1"
  local ast_path="$project_dir/Compiler/Ast.clasp"
  local before='renderStringLiteral value = encode value'
  local after='renderStringLiteral value = textConcat [encode value, ""]'

  if ! grep -F "$before" "$ast_path" >/dev/null; then
    printf 'compiler module speed probe could not find expected body in %s\n' "$ast_path" >&2
    exit 1
  fi
  sed -i "s/$before/$after/" "$ast_path"
  if ! grep -F "$after" "$ast_path" >/dev/null; then
    printf 'compiler module speed probe failed to edit %s\n' "$ast_path" >&2
    exit 1
  fi
}

native_incremental_truthy() {
  case "$1" in
    1|true|TRUE|True|yes|YES|Yes|on|ON|On)
      return 0
      ;;
  esac

  return 1
}

native_incremental_file_fingerprint() {
  local path="$1"

  if [[ ! -e "$path" ]]; then
    printf 'missing:%s\n' "$path"
    return 0
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{ print $1 }'
    return 0
  fi

  cksum "$path" | awk '{ print $1 "-" $2 }'
}

selfhost_warmup_marker_path() {
  local selfhost_cache_root="$1"
  local marker_root="$selfhost_cache_root/warmup-markers"
  local embedded_image_fingerprint=""
  local claspc_fingerprint=""
  local script_fingerprint=""
  local key=""

  embedded_image_fingerprint="$(native_incremental_file_fingerprint "$project_root/src/embedded.compiler.native.image.json")"
  claspc_fingerprint="$(native_incremental_file_fingerprint "$claspc_bin")"
  script_fingerprint="$(native_incremental_file_fingerprint "$project_root/scripts/measure-native-incremental.sh")"
  key="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
    "selfhost-warmup-v1" \
    "$embedded_image_fingerprint" \
    "$claspc_fingerprint" \
    "$script_fingerprint" \
    "${CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE:-}" \
    "${CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS:-}" \
    "${CLASP_NATIVE_BUNDLE_JOBS:-}" \
    "${CLASP_NATIVE_IMAGE_SECTION_JOBS:-}" |
    { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{ print $1 }'; else cksum | awk '{ print $1 "-" $2 }'; fi; })"

  mkdir -p "$marker_root"
  printf '%s/selfhost-%s.ok\n' "$marker_root" "$key"
}

record_time_skipped() {
  local path="$1"

  {
    printf 'real 0.00\n'
    printf 'user 0.00\n'
    printf 'sys 0.00\n'
  } >"$path"
}

run_native_cli_body_change() {
  local native_project_dir="$probe_root/native-image-project"
  local native_project_path="$native_project_dir/Main.clasp"
  local native_cache_root="$shared_cache_root/native-cache"
  local check_project_dir="$probe_root/check-project"
  local check_project_path="$check_project_dir/Main.clasp"
  local check_cache_root="$shared_cache_root/check-cache"

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
  local selfhost_cache_root="$shared_cache_root/selfhost-cache"
  local warmup_marker_path=""
  local reuse_warmup=0

  write_selfhost_probe_project "$selfhost_project_dir" "$selfhost_project_path"
  mkdir -p "$selfhost_cache_root"

  warmup_marker_path="$(selfhost_warmup_marker_path "$selfhost_cache_root")"
  if native_incremental_truthy "${CLASP_NATIVE_INCREMENTAL_REUSE_WARMUP:-0}" && [[ -f "$warmup_marker_path" ]]; then
    reuse_warmup=1
    : >"$probe_root/selfhost.image.cold.log"
    printf '{"status":"skipped","reason":"warmup-reused"}\n' >"$probe_root/selfhost.image.cold.native.image.json"
    record_time_skipped "$probe_root/selfhost.image.cold.time"
  else
    "$time_bin" -p -o "$probe_root/selfhost.image.cold.time" \
      env XDG_CACHE_HOME="$selfhost_cache_root" CLASP_NATIVE_TRACE_CACHE=1 CLASP_NATIVE_TRACE_HOST=1 CLASP_NATIVE_TRACE_TIMING=1 CLASPC_BIN="$claspc_bin" \
      bash "$project_root/src/scripts/run-native-tool.sh" \
      "$project_root/src/embedded.compiler.native.image.json" \
      nativeImageProjectText \
      "--project-entry=$selfhost_project_path" \
      "$probe_root/selfhost.image.cold.native.image.json" >"$probe_root/selfhost.image.cold.log" 2>&1
  fi
  "$time_bin" -p -o "$probe_root/selfhost.check.cold.time" \
    env XDG_CACHE_HOME="$selfhost_cache_root" CLASP_NATIVE_TRACE_CACHE=1 CLASP_NATIVE_TRACE_HOST=1 CLASP_NATIVE_TRACE_TIMING=1 \
    "$claspc_bin" --json check "$selfhost_project_path" \
    >"$probe_root/selfhost.check.cold.json" 2>"$probe_root/selfhost.check.cold.log"
  if [[ "$reuse_warmup" != "1" ]]; then
    printf 'ok\n' >"$warmup_marker_path"
  fi

  sed -i "s/\"hello$probe_suffix\"/\"hullo$probe_suffix\"/" "$selfhost_project_dir/Helper.clasp"

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
    --time "checkBodyChange=$probe_root/selfhost.check.body-change.time"
    --time "imageBodyChange=$probe_root/selfhost.image.body-change.time"
  )
  if [[ "$reuse_warmup" == "1" ]]; then
    guard_args+=(--meta warmupReused=true)
  else
    guard_args+=(--meta warmupReused=false)
  fi
  append_guard_options
  node "${guard_args[@]}"
}

run_selfhost_compiler_module_body_change() {
  local check_project_dir="$probe_root/compiler-module-check-project"
  local check_project_path="$check_project_dir/CompilerMain.clasp"
  local check_cache_root="$shared_cache_root/compiler-module-check-cache"
  local image_project_dir="$probe_root/compiler-module-image-project"
  local image_project_path="$image_project_dir/CompilerMain.clasp"
  local image_cache_root="$shared_cache_root/compiler-module-image-cache"
  local include_image_probe=0

  if native_incremental_truthy "${CLASP_NATIVE_INCREMENTAL_COMPILER_MODULE_IMAGE_PROBE:-0}"; then
    include_image_probe=1
  fi

  # This scenario proves the cold -> body-change path inside one run. Reusing
  # its per-scenario project/cache across verifier invocations can make the
  # second step a plain hit from an older edited probe instead of validating the
  # current edit.
  rm -rf "$check_project_dir" "$check_cache_root"
  copy_compiler_probe_project "$check_project_dir"
  mkdir -p "$check_cache_root"
  "$time_bin" -p -o "$probe_root/compiler-module.check.cold.time" \
    env XDG_CACHE_HOME="$check_cache_root" CLASP_NATIVE_TRACE_CACHE=1 CLASP_NATIVE_TRACE_HOST=1 CLASP_NATIVE_TRACE_TIMING=1 \
    "$claspc_bin" --json check "$check_project_path" \
    >"$probe_root/compiler-module.check.cold.json" 2>"$probe_root/compiler-module.check.cold.log"
  edit_compiler_probe_module_body "$check_project_dir"
  "$time_bin" -p -o "$probe_root/compiler-module.check.body-change.time" \
    env XDG_CACHE_HOME="$check_cache_root" CLASP_NATIVE_TRACE_CACHE=1 CLASP_NATIVE_TRACE_HOST=1 CLASP_NATIVE_TRACE_TIMING=1 \
    "$claspc_bin" --json check "$check_project_path" \
    >"$probe_root/compiler-module.check.body-change.json" 2>"$probe_root/compiler-module.check.body-change.log"

  guard_args=(
    "$project_root/scripts/native-incremental-guard.mjs"
    selfhost-compiler-module-body-change
    --check-log "$probe_root/compiler-module.check.body-change.log"
    --time "compilerCheckCold=$probe_root/compiler-module.check.cold.time"
    --time "compilerCheckBodyChange=$probe_root/compiler-module.check.body-change.time"
  )

  if [[ "$include_image_probe" == "1" ]]; then
    rm -rf "$image_project_dir" "$image_cache_root"
    copy_compiler_probe_project "$image_project_dir"
    mkdir -p "$image_cache_root"
    "$time_bin" -p -o "$probe_root/compiler-module.image.cold.time" \
      env XDG_CACHE_HOME="$image_cache_root" CLASP_NATIVE_TRACE_CACHE=1 CLASP_NATIVE_TRACE_HOST=1 CLASP_NATIVE_TRACE_TIMING=1 CLASPC_BIN="$claspc_bin" \
      bash "$project_root/src/scripts/run-native-tool.sh" \
      "$project_root/src/embedded.compiler.native.image.json" \
      nativeImageProjectText \
      "--project-entry=$image_project_path" \
      "$probe_root/compiler-module.image.cold.native.image.json" >"$probe_root/compiler-module.image.cold.log" 2>&1
    edit_compiler_probe_module_body "$image_project_dir"
    "$time_bin" -p -o "$probe_root/compiler-module.image.body-change.time" \
      env XDG_CACHE_HOME="$image_cache_root" CLASP_NATIVE_TRACE_CACHE=1 CLASP_NATIVE_TRACE_HOST=1 CLASP_NATIVE_TRACE_TIMING=1 CLASPC_BIN="$claspc_bin" \
      bash "$project_root/src/scripts/run-native-tool.sh" \
      "$project_root/src/embedded.compiler.native.image.json" \
      nativeImageProjectText \
      "--project-entry=$image_project_path" \
      "$probe_root/compiler-module.image.body-change.native.image.json" >"$probe_root/compiler-module.image.body-change.log" 2>&1
    guard_args+=(
      --image-log "$probe_root/compiler-module.image.body-change.log"
      --time "compilerImageCold=$probe_root/compiler-module.image.cold.time"
      --time "compilerImageBodyChange=$probe_root/compiler-module.image.body-change.time"
      --meta compilerModuleImageProbe=full
    )
  else
    guard_args+=(--meta compilerModuleImageProbe=skipped)
  fi

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
  selfhost-compiler-module-body-change)
    run_selfhost_compiler_module_body_change
    ;;
esac
