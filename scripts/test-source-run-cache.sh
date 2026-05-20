#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-source-run-cache.XXXXXX")"

cleanup() {
  rm -rf "$test_root" >/dev/null 2>&1 || true
}
trap cleanup EXIT

export XDG_CACHE_HOME="$test_root/xdg-cache"
mkdir -p "$XDG_CACHE_HOME"

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN "$project_root/scripts/resolve-claspc.sh")"
project_dir="$test_root/project"
entry_path="$project_dir/Main.clasp"
first_log="$test_root/first.log"
second_log="$test_root/second.log"
third_log="$test_root/third.log"
mkdir -p "$project_dir"

cat >"$entry_path" <<'CLASP'
module Main

main : Str
main = "source-run-cache-v1"
CLASP

first_output="$(
  CLASP_NATIVE_TRACE_CACHE=1 timeout 180 "$claspc_bin" run "$entry_path" 2>"$first_log"
)"
printf '%s\n' "$first_output" | grep -Fx 'source-run-cache-v1' >/dev/null

second_output="$(
  CLASP_NATIVE_TRACE_CACHE=1 timeout 60 "$claspc_bin" run "$entry_path" 2>"$second_log"
)"
printf '%s\n' "$second_output" | grep -Fx 'source-run-cache-v1' >/dev/null
grep -F '[claspc-cache] run-binary fast hit path=' "$second_log" >/dev/null

cat >"$entry_path" <<'CLASP'
module Main

main : Str
main = "source-run-cache-v2"
CLASP

third_output="$(
  CLASP_NATIVE_TRACE_CACHE=1 timeout 180 "$claspc_bin" run "$entry_path" 2>"$third_log"
)"
printf '%s\n' "$third_output" | grep -Fx 'source-run-cache-v2' >/dev/null
if grep -F '[claspc-cache] run-binary fast hit path=' "$third_log" >/dev/null; then
  printf 'source-run cache reused a stale backend binary after source change\n' >&2
  exit 1
fi

printf 'test-source-run-cache: ok\n'
