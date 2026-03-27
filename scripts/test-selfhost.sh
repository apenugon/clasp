#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-$project_root/.clasp-test-tmp}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-selfhost.XXXXXX")"
claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
check_output="$test_root/selfhost.check.txt"
image_output="$test_root/selfhost.native.image.json"
sample_project_root="$test_root/project"
sample_entry_path="$sample_project_root/Main.clasp"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

run_export() {
  local result_var="$1"
  local export_name="$2"
  local export_path="$3"
  local log_path="$4"

  CLASPC_BIN="$claspc_bin" bash "$project_root/src/scripts/run-native-tool.sh" \
    "$project_root/src/embedded.compiler.native.image.json" \
    "$export_name" \
    "--project-entry=$sample_entry_path" \
    "$export_path" >"$log_path" 2>&1 &

  printf -v "$result_var" '%s' "$!"
}

wait_for_export() {
  local pid="$1"
  local log_path="$2"

  if wait "$pid"; then
    rm -f "$log_path"
    return 0
  fi

  cat "$log_path" >&2
  rm -f "$log_path"
  return 1
}

mkdir -p "$sample_project_root"
cat >"$sample_entry_path" <<'EOF'
module Main

import Helper

main : Str
main = helper "hello"
EOF

cat >"$sample_project_root/Helper.clasp" <<'EOF'
module Helper

helper : Str -> Str
helper value = value
EOF

check_log="$test_root/check.log"
image_log="$test_root/image.log"
check_pid=""
image_pid=""
run_export check_pid checkProjectText "$check_output" "$check_log"
run_export image_pid nativeImageProjectText "$image_output" "$image_log"

wait_for_export "$check_pid" "$check_log"
wait_for_export "$image_pid" "$image_log"

test -s "$check_output"
test -s "$image_output"
