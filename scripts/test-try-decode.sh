#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_TRY_DECODE_TIMEOUT_SECS:-180}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_TRY_DECODE_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-try-decode.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN CLASP_PROJECT_ROOT="$project_root" "$project_root/scripts/resolve-claspc.sh")"
source_path="$test_root/TryDecode.clasp"
compiled_js="$test_root/try-decode.mjs"
native_binary="$test_root/try-decode"
native_output="$test_root/native-output.json"
check_output="$test_root/check-output.json"

cat >"$source_path" <<'EOF'
module Main

record TryDecodeItem = {
  name : Str,
  count : Int
}

record TryDecodeReport = {
  validName : Str,
  validCount : Int,
  malformedIsErr : Bool,
  malformedMessage : Str,
  listLength : Int
}

itemName : Result TryDecodeItem -> Str
itemName result = match result {
  Ok item -> item.name,
  Err message -> textConcat ["err:", message]
}

itemCount : Result TryDecodeItem -> Int
itemCount result = match result {
  Ok item -> item.count,
  Err message -> 0
}

isItemErr : Result TryDecodeItem -> Bool
isItemErr result = match result {
  Ok item -> false,
  Err message -> true
}

itemError : Result TryDecodeItem -> Str
itemError result = match result {
  Ok item -> "",
  Err message -> message
}

listLengthOrZero : Result [TryDecodeItem] -> Int
listLengthOrZero result = match result {
  Ok items -> length items,
  Err message -> 0
}

main : Str
main = {
  let valid = tryDecode TryDecodeItem "{\"name\":\"agent\",\"count\":3}";
  let malformed = tryDecode TryDecodeItem "{not-json";
  let decodedList = tryDecode [TryDecodeItem] "[{\"name\":\"builder\",\"count\":1},{\"name\":\"verifier\",\"count\":2}]";
  encode
    (TryDecodeReport {
      validName = itemName valid,
      validCount = itemCount valid,
      malformedIsErr = isItemErr malformed,
      malformedMessage = itemError malformed,
      listLength = listLengthOrZero decodedList
    })
}
EOF

if ! timeout "$timeout_secs" "$claspc_bin" --json check "$source_path" >"$check_output"; then
  cat "$check_output" >&2
  exit 1
fi
if ! grep -F '"status":"ok"' "$check_output" >/dev/null; then
  cat "$check_output" >&2
  exit 1
fi
timeout "$timeout_secs" "$claspc_bin" compile "$source_path" -o "$compiled_js" >/dev/null

timeout "$timeout_secs" node --input-type=module - "$compiled_js" <<'NODE'
import { pathToFileURL } from "node:url";

const modulePath = process.argv[2];
const mod = await import(pathToFileURL(modulePath));
const report = JSON.parse(mod.main);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(report.validName === "agent", `js validName ${report.validName}`);
assert(report.validCount === 3, `js validCount ${report.validCount}`);
assert(report.malformedIsErr === true, "js malformed JSON should return Err");
assert(typeof report.malformedMessage === "string" && report.malformedMessage.length > 0, "js malformed message");
assert(report.listLength === 2, `js listLength ${report.listLength}`);
NODE

env RUSTC=/definitely-missing-rustc timeout "$timeout_secs" "$claspc_bin" compile "$source_path" -o "$native_binary" >/dev/null
timeout "$timeout_secs" "$native_binary" >"$native_output"

node - "$native_output" <<'NODE'
const fs = require("node:fs");

const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(report.validName === "agent", `native validName ${report.validName}`);
assert(report.validCount === 3, `native validCount ${report.validCount}`);
assert(report.malformedIsErr === true, "native malformed JSON should return Err");
assert(typeof report.malformedMessage === "string" && report.malformedMessage.length > 0, "native malformed message");
assert(report.listLength === 2, `native listLength ${report.listLength}`);
NODE

printf 'try-decode-ok\n'
