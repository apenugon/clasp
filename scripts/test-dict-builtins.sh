#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_DICT_BUILTINS_TIMEOUT_SECS:-120}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_DICT_BUILTINS_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-dict-builtins.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN -u RUSTC "$project_root/scripts/resolve-claspc.sh")"
source_path="$test_root/DictBuiltins.clasp"
compiled_js="$test_root/dict-builtins.mjs"
native_binary="$test_root/dict-builtins"
native_output="$test_root/native-output.json"

cat >"$source_path" <<'EOF'
module Main

record DictBuiltinReport = {
  lookup : Str,
  missing : Str,
  hasBuild : Bool,
  hasRemovedReview : Bool,
  keys : Str,
  values : Str,
  intLookup : Int,
  intSum : Int
}

lookupText : Str -> Dict Str Str -> Str
lookupText key dict = match dictGet key dict {
  Ok value -> value,
  Err message -> message
}

lookupInt : Str -> Dict Str Int -> Int
lookupInt key dict = match dictGet key dict {
  Ok value -> value,
  Err message -> 0
}

sumStep : Int -> Int -> Int
sumStep total item = intAdd total item

main : Str
main = {
  let statuses = dictSet "review" "done" (dictSet "build" "queued" dictEmpty);
  let withoutReview = dictRemove "review" statuses;
  let counts = dictSet "review" 2 (dictSet "build" 3 dictEmpty);
  encode
    (DictBuiltinReport {
      lookup = lookupText "review" statuses,
      missing = lookupText "missing" statuses,
      hasBuild = dictHas "build" statuses,
      hasRemovedReview = dictHas "review" withoutReview,
      keys = textJoin "," (dictKeys statuses),
      values = textJoin "," (dictValues statuses),
      intLookup = lookupInt "review" counts,
      intSum = fold sumStep 0 (dictValues counts)
    })
}
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

assert(report.lookup === "done", `js lookup ${report.lookup}`);
assert(typeof report.missing === "string" && report.missing.includes("missing"), `js missing ${report.missing}`);
assert(report.hasBuild === true, `js hasBuild ${report.hasBuild}`);
assert(report.hasRemovedReview === false, `js hasRemovedReview ${report.hasRemovedReview}`);
assert(report.keys === "build,review", `js keys ${report.keys}`);
assert(report.values === "queued,done", `js values ${report.values}`);
assert(report.intLookup === 2, `js intLookup ${report.intLookup}`);
assert(report.intSum === 5, `js intSum ${report.intSum}`);
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

assert(report.lookup === "done", `native lookup ${report.lookup}`);
assert(typeof report.missing === "string" && report.missing.includes("missing"), `native missing ${report.missing}`);
assert(report.hasBuild === true, `native hasBuild ${report.hasBuild}`);
assert(report.hasRemovedReview === false, `native hasRemovedReview ${report.hasRemovedReview}`);
assert(report.keys === "build,review", `native keys ${report.keys}`);
assert(report.values === "queued,done", `native values ${report.values}`);
assert(report.intLookup === 2, `native intLookup ${report.intLookup}`);
assert(report.intSum === 5, `native intSum ${report.intSum}`);
NODE

printf 'test-dict-builtins: ok\n'
