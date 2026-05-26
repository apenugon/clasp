#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_INT_BUILTINS_TIMEOUT_SECS:-120}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_INT_BUILTINS_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-int-builtins.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN -u RUSTC "$project_root/scripts/resolve-claspc.sh")"
source_path="$test_root/IntBuiltins.clasp"
compiled_js="$test_root/int-builtins.mjs"
native_binary="$test_root/int-builtins"
native_output="$test_root/native-output.json"

cat >"$source_path" <<'EOF'
module Main

record IntBuiltinReport = {
  sum : Int,
  difference : Int,
  folded : Int,
  nested : Int,
  restored : Int
}

bump : Int -> Int
bump value = intAdd value 1

decrement : Int -> Int
decrement value = intSubtract value 1

sumStep : Int -> Int -> Int
sumStep total item = intAdd total item

main : Str
main =
  encode
    (IntBuiltinReport {
      sum = intAdd 40 2,
      difference = intSubtract 12 5,
      folded = fold sumStep 0 [1, 2, 3, 4],
      nested = intSubtract (intAdd 20 25) 3,
      restored = decrement (bump 7)
    })
EOF

timeout "$timeout_secs" "$claspc_bin" --json check "$source_path" | grep -F '"status":"ok"' >/dev/null
timeout "$timeout_secs" "$claspc_bin" compile "$source_path" -o "$compiled_js" >/dev/null

timeout "$timeout_secs" node --input-type=module - "$compiled_js" <<'NODE'
import { pathToFileURL } from "node:url";

const modulePath = process.argv[2];
const mod = await import(pathToFileURL(modulePath));
const report = JSON.parse(mod.main);

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

assert(report.sum === 42, `js sum ${report.sum}`);
assert(report.difference === 7, `js difference ${report.difference}`);
assert(report.folded === 10, `js folded ${report.folded}`);
assert(report.nested === 42, `js nested ${report.nested}`);
assert(report.restored === 7, `js restored ${report.restored}`);
NODE

env RUSTC=/definitely-missing-rustc timeout "$timeout_secs" "$claspc_bin" compile "$source_path" -o "$native_binary" >/dev/null
timeout "$timeout_secs" "$native_binary" >"$native_output"

node - "$native_output" <<'NODE'
const fs = require("node:fs");

const outputPath = process.argv[2];
const report = JSON.parse(fs.readFileSync(outputPath, "utf8"));

function assert(condition, message) {
  if (!condition) {
    throw new Error(`${outputPath}: ${message}`);
  }
}

assert(report.sum === 42, `native sum ${report.sum}`);
assert(report.difference === 7, `native difference ${report.difference}`);
assert(report.folded === 10, `native folded ${report.folded}`);
assert(report.nested === 42, `native nested ${report.nested}`);
assert(report.restored === 7, `native restored ${report.restored}`);
NODE

printf 'test-int-builtins: ok\n'
