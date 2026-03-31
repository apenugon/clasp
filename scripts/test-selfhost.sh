#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-$project_root/.clasp-test-tmp}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-selfhost.XXXXXX")"
claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
sample_project_root="$test_root/project"
sample_entry_path="$sample_project_root/Main.clasp"
cache_root="$test_root/cache-root"

check_output_first="$test_root/selfhost.check.first.json"
check_output_second="$test_root/selfhost.check.second.json"
check_output_third="$test_root/selfhost.check.third.json"
check_output_fourth="$test_root/selfhost.check.fourth.json"
check_log_first="$test_root/selfhost.check.first.log"
check_log_second="$test_root/selfhost.check.second.log"
check_log_third="$test_root/selfhost.check.third.log"
check_log_fourth="$test_root/selfhost.check.fourth.log"

image_output_first="$test_root/selfhost.native-image.first.json"
image_output_second="$test_root/selfhost.native-image.second.json"
image_output_third="$test_root/selfhost.native-image.third.json"
image_output_fourth="$test_root/selfhost.native-image.fourth.json"
image_log_first="$test_root/selfhost.native-image.first.log"
image_log_second="$test_root/selfhost.native-image.second.log"
image_log_third="$test_root/selfhost.native-image.third.log"
image_log_fourth="$test_root/selfhost.native-image.fourth.log"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

mkdir -p "$sample_project_root"
cat >"$sample_entry_path" <<'EOF'
module Main

import Helper

main : Str
main = helper "input"
EOF

cat >"$sample_project_root/Helper.clasp" <<'EOF'
module Helper

helper : Str -> Str
helper value = "hello"
EOF

mkdir -p "$cache_root"

XDG_CACHE_HOME="$cache_root" CLASP_NATIVE_TRACE_CACHE=1 "$claspc_bin" --json check "$sample_entry_path" >"$check_output_first" 2>"$check_log_first"
XDG_CACHE_HOME="$cache_root" CLASP_NATIVE_TRACE_CACHE=1 CLASPC_BIN="$claspc_bin" \
  bash "$project_root/src/scripts/run-native-tool.sh" \
  "$project_root/src/embedded.compiler.native.image.json" \
  nativeImageProjectText \
  "--project-entry=$sample_entry_path" \
  "$image_output_first" >"$image_log_first" 2>&1

XDG_CACHE_HOME="$cache_root" CLASP_NATIVE_TRACE_CACHE=1 "$claspc_bin" --json check "$sample_entry_path" >"$check_output_second" 2>"$check_log_second"
XDG_CACHE_HOME="$cache_root" CLASP_NATIVE_TRACE_CACHE=1 CLASPC_BIN="$claspc_bin" \
  bash "$project_root/src/scripts/run-native-tool.sh" \
  "$project_root/src/embedded.compiler.native.image.json" \
  nativeImageProjectText \
  "--project-entry=$sample_entry_path" \
  "$image_output_second" >"$image_log_second" 2>&1

cmp -s "$check_output_first" "$check_output_second"
cmp -s "$image_output_first" "$image_output_second"
grep -F '[claspc-cache] module-summary hit module=Helper path=' "$check_log_second" >/dev/null
grep -F '[claspc-cache] module-summary hit module=Main path=' "$check_log_second" >/dev/null
grep -F '[claspc-cache] source-export hit export=nativeImageProjectText path=' "$image_log_second" >/dev/null

sed -i 's/"hello"/"hullo"/' "$sample_project_root/Helper.clasp"

XDG_CACHE_HOME="$cache_root" CLASP_NATIVE_TRACE_CACHE=1 "$claspc_bin" --json check "$sample_entry_path" >"$check_output_third" 2>"$check_log_third"
XDG_CACHE_HOME="$cache_root" CLASP_NATIVE_TRACE_CACHE=1 CLASPC_BIN="$claspc_bin" \
  bash "$project_root/src/scripts/run-native-tool.sh" \
  "$project_root/src/embedded.compiler.native.image.json" \
  nativeImageProjectText \
  "--project-entry=$sample_entry_path" \
  "$image_output_third" >"$image_log_third" 2>&1

grep -F '"status":"ok"' "$check_output_third" >/dev/null
grep -F '[claspc-cache] module-summary miss module=Helper path=' "$check_log_third" >/dev/null
grep -F '[claspc-cache] module-summary hit module=Main path=' "$check_log_third" >/dev/null
grep -F '[claspc-cache] source-export miss export=nativeImageProjectText path=' "$image_log_third" >/dev/null
grep -F '[claspc-cache] build-plan hit path=' "$image_log_third" >/dev/null
grep -F '[claspc-cache] decl-module miss module=Helper path=' "$image_log_third" >/dev/null
grep -F '[claspc-cache] decl-module hit module=Main path=' "$image_log_third" >/dev/null

XDG_CACHE_HOME="$cache_root" CLASP_NATIVE_TRACE_CACHE=1 "$claspc_bin" --json check "$sample_entry_path" >"$check_output_fourth" 2>"$check_log_fourth"
XDG_CACHE_HOME="$cache_root" CLASP_NATIVE_TRACE_CACHE=1 CLASPC_BIN="$claspc_bin" \
  bash "$project_root/src/scripts/run-native-tool.sh" \
  "$project_root/src/embedded.compiler.native.image.json" \
  nativeImageProjectText \
  "--project-entry=$sample_entry_path" \
  "$image_output_fourth" >"$image_log_fourth" 2>&1

cmp -s "$check_output_third" "$check_output_fourth"
cmp -s "$image_output_third" "$image_output_fourth"
grep -F '[claspc-cache] module-summary hit module=Helper path=' "$check_log_fourth" >/dev/null
grep -F '[claspc-cache] module-summary hit module=Main path=' "$check_log_fourth" >/dev/null
grep -F '[claspc-cache] source-export hit export=nativeImageProjectText path=' "$image_log_fourth" >/dev/null
