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
bad_single_and_path="$test_root/BadSingleAnd.clasp"
bad_single_or_path="$test_root/BadSingleOr.clasp"
bad_concat_path="$test_root/BadConcat.clasp"
compiled_js="$test_root/int-builtins.mjs"
native_binary="$test_root/int-builtins"
native_output="$test_root/native-output.json"

cat >"$source_path" <<'EOF'
module Main

record IntBuiltinReport = {
  sum : Int,
  difference : Int,
  operatorDifference : Int,
  nestedOperatorDifference : Int,
  negativeLiteral : Int,
  subtractNegativeLiteral : Int,
  folded : Int,
  flattened : Str,
  flattenedCount : Int,
  containsPlan : Bool,
  containsMissing : Bool,
  containsEmpty : Bool,
  nested : Int,
  restored : Int,
  logicAnd : Bool,
  logicOr : Bool,
  logicPrecedence : Bool,
  shortAnd : Bool,
  shortOr : Bool
}

bump : Int -> Int
bump value = intAdd value 1

decrement : Int -> Int
decrement value = intSubtract value 1

sumStep : Int -> Int -> Int
sumStep total item = intAdd total item

crashBool : Bool -> Bool
crashBool value = decode Bool "{not-json"

main : Str
main =
  encode
    (IntBuiltinReport {
      sum = intAdd 40 2,
      difference = intSubtract 12 5,
      operatorDifference = 12 - 5,
      nestedOperatorDifference = (20 - 3) - 5,
      negativeLiteral = -5,
      subtractNegativeLiteral = 12 - (-5),
      folded = fold sumStep 0 [1, 2, 3, 4],
      flattened = textJoin "/" (concat [["plan"], ["build"], ["verify"]]),
      flattenedCount = length (concat [[1, 2], [3, 4]]),
      containsPlan = textContains "plan/build/verify" "build",
      containsMissing = textContains "plan/build/verify" "ship",
      containsEmpty = textContains "plan" "",
      nested = intSubtract (intAdd 20 25) 3,
      restored = decrement (bump 7),
      logicAnd = true && true,
      logicOr = false || true,
      logicPrecedence = true || false && false,
      shortAnd = false && crashBool true,
      shortOr = true || crashBool true
    })
EOF

cat >"$bad_single_and_path" <<'EOF'
module Main

main : Bool
main = true & false
EOF

cat >"$bad_single_or_path" <<'EOF'
module Main

main : Bool
main = true | false
EOF

cat >"$bad_concat_path" <<'EOF'
module Main

main : [Int]
main = concat [1, 2]
EOF

timeout "$timeout_secs" "$claspc_bin" --json check "$source_path" | grep -F '"status":"ok"' >/dev/null
if timeout "$timeout_secs" "$claspc_bin" --json check "$bad_single_and_path" >/dev/null 2>&1; then
  printf 'single & should not parse as logical and\n' >&2
  exit 1
fi
if timeout "$timeout_secs" "$claspc_bin" --json check "$bad_single_or_path" >/dev/null 2>&1; then
  printf 'single | should not parse as logical or\n' >&2
  exit 1
fi
if timeout "$timeout_secs" "$claspc_bin" --json check "$bad_concat_path" >/dev/null 2>&1; then
  printf 'concat should reject non-nested lists\n' >&2
  exit 1
fi
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
assert(report.operatorDifference === 7, `js operatorDifference ${report.operatorDifference}`);
assert(report.nestedOperatorDifference === 12, `js nestedOperatorDifference ${report.nestedOperatorDifference}`);
assert(report.negativeLiteral === -5, `js negativeLiteral ${report.negativeLiteral}`);
assert(report.subtractNegativeLiteral === 17, `js subtractNegativeLiteral ${report.subtractNegativeLiteral}`);
assert(report.folded === 10, `js folded ${report.folded}`);
assert(report.flattened === "plan/build/verify", `js flattened ${report.flattened}`);
assert(report.flattenedCount === 4, `js flattenedCount ${report.flattenedCount}`);
assert(report.containsPlan === true, `js containsPlan ${report.containsPlan}`);
assert(report.containsMissing === false, `js containsMissing ${report.containsMissing}`);
assert(report.containsEmpty === true, `js containsEmpty ${report.containsEmpty}`);
assert(report.nested === 42, `js nested ${report.nested}`);
assert(report.restored === 7, `js restored ${report.restored}`);
assert(report.logicAnd === true, `js logicAnd ${report.logicAnd}`);
assert(report.logicOr === true, `js logicOr ${report.logicOr}`);
assert(report.logicPrecedence === true, `js logicPrecedence ${report.logicPrecedence}`);
assert(report.shortAnd === false, `js shortAnd ${report.shortAnd}`);
assert(report.shortOr === true, `js shortOr ${report.shortOr}`);
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
assert(report.operatorDifference === 7, `native operatorDifference ${report.operatorDifference}`);
assert(report.nestedOperatorDifference === 12, `native nestedOperatorDifference ${report.nestedOperatorDifference}`);
assert(report.negativeLiteral === -5, `native negativeLiteral ${report.negativeLiteral}`);
assert(report.subtractNegativeLiteral === 17, `native subtractNegativeLiteral ${report.subtractNegativeLiteral}`);
assert(report.folded === 10, `native folded ${report.folded}`);
assert(report.flattened === "plan/build/verify", `native flattened ${report.flattened}`);
assert(report.flattenedCount === 4, `native flattenedCount ${report.flattenedCount}`);
assert(report.containsPlan === true, `native containsPlan ${report.containsPlan}`);
assert(report.containsMissing === false, `native containsMissing ${report.containsMissing}`);
assert(report.containsEmpty === true, `native containsEmpty ${report.containsEmpty}`);
assert(report.nested === 42, `native nested ${report.nested}`);
assert(report.restored === 7, `native restored ${report.restored}`);
assert(report.logicAnd === true, `native logicAnd ${report.logicAnd}`);
assert(report.logicOr === true, `native logicOr ${report.logicOr}`);
assert(report.logicPrecedence === true, `native logicPrecedence ${report.logicPrecedence}`);
assert(report.shortAnd === false, `native shortAnd ${report.shortAnd}`);
assert(report.shortOr === true, `native shortOr ${report.shortOr}`);
NODE

printf 'test-int-builtins: ok\n'
