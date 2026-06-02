#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-native-export-host-content-scope.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN -u RUSTC "$project_root/scripts/resolve-claspc.sh")"
time_bin="$(which time 2>/dev/null || true)"
max_second_seconds="${CLASP_TEST_NATIVE_EXPORT_HOST_CONTENT_SCOPE_SECOND_MAX_SECONDS:-5}"
timeout_secs="${CLASP_TEST_NATIVE_EXPORT_HOST_CONTENT_SCOPE_TIMEOUT_SECS:-90}"
first_cache_root="$test_root/cache-a"
second_cache_root="$test_root/cache-b"
source_path="$test_root/Main.clasp"
first_output="$test_root/first.txt"
second_output="$test_root/second.txt"
first_log="$test_root/first.log"
second_log="$test_root/second.log"
second_time="$test_root/second.time"

if [[ -z "$time_bin" || ! -x "$time_bin" ]]; then
  printf 'missing time binary\n' >&2
  exit 1
fi

mkdir -p "$first_cache_root" "$second_cache_root"
cat >"$source_path" <<'CLASP'
module Main

main : Str
main = "ok"
CLASP

env XDG_CACHE_HOME="$first_cache_root" \
  CLASP_NATIVE_TRACE_HOST=1 \
  RUSTC=/definitely-missing-rustc \
  timeout "$timeout_secs" \
  "$claspc_bin" exec-image "$project_root/src/embedded.compiler.native.image.json" \
    checkSourceText "$source_path" "$first_output" \
  >/dev/null 2>"$first_log"

"$time_bin" -p -o "$second_time" \
  env XDG_CACHE_HOME="$second_cache_root" \
    CLASP_NATIVE_TRACE_HOST=1 \
    RUSTC=/definitely-missing-rustc \
    timeout "$timeout_secs" \
    "$claspc_bin" exec-image "$project_root/src/embedded.compiler.native.image.json" \
      checkSourceText "$source_path" "$second_output" \
    >/dev/null 2>"$second_log"

cmp -s "$first_output" "$second_output"

node - "$second_time" "$max_second_seconds" <<'NODE'
const fs = require("node:fs");

const timeText = fs.readFileSync(process.argv[2], "utf8");
const maxSeconds = Number(process.argv[3]);
const match = /^real\s+([0-9]+(?:[.][0-9]+)?)$/m.exec(timeText);
if (!match) {
  throw new Error(`missing real timing in ${process.argv[2]}: ${timeText}`);
}
const realSeconds = Number(match[1]);
if (!(realSeconds < maxSeconds)) {
  throw new Error(`second compiler export through a different XDG cache took ${realSeconds}s, expected < ${maxSeconds}s`);
}
NODE

printf 'native-export-host-content-scope-ok\n'
