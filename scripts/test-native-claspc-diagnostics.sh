#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-native-claspc-diagnostics.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN "$project_root/scripts/resolve-claspc.sh")"

parser_source="$test_root/parser-empty-expression.clasp"
checker_source="$test_root/checker-type-mismatch.clasp"
unknown_name_source="$test_root/checker-unknown-name.clasp"
valid_multiline_source="$test_root/parser-valid-multiline-rhs.clasp"
parser_json="$test_root/parser.json"
parser_pretty="$test_root/parser.pretty"
checker_json="$test_root/checker.json"
checker_pretty="$test_root/checker.pretty"
unknown_name_json="$test_root/checker-unknown-name.json"
unknown_name_pretty="$test_root/checker-unknown-name.pretty"
valid_multiline_json="$test_root/parser-valid-multiline-rhs.json"
polymorphism_json="$test_root/polymorphism.json"

cat >"$parser_source" <<'EOF'
module Main

main =
EOF

cat >"$checker_source" <<'EOF'
module Main

main : Str
main = 1
EOF

cat >"$unknown_name_source" <<'EOF'
module Main

renderName : Str -> Str
renderName value = value

main : Str
main = renderNmae "Ada"
EOF

cat >"$valid_multiline_source" <<'EOF'
module Main

main : Str
main =
  if true then
    "ok"
  else
    "fallback"
EOF

expect_failure() {
  local output_path="$1"
  shift

  set +e
  "$@" >"$output_path" 2>&1
  local status=$?
  set -e

  if [[ "$status" == "0" ]]; then
    printf 'expected command to fail: %s\n' "$*" >&2
    sed -n '1,80p' "$output_path" >&2 || true
    exit 1
  fi
}

timeout 30 "$claspc_bin" --json check "$parser_source" >"$parser_json" 2>"$test_root/parser.stderr" || parser_json_status=$?
parser_json_status="${parser_json_status:-0}"
if [[ "$parser_json_status" == "0" ]]; then
  printf 'expected parser json check to fail\n' >&2
  cat "$parser_json" >&2
  exit 1
fi

timeout 30 "$claspc_bin" --json check "$checker_source" >"$checker_json" 2>"$test_root/checker.stderr" || checker_json_status=$?
checker_json_status="${checker_json_status:-0}"
if [[ "$checker_json_status" == "0" ]]; then
  printf 'expected checker json check to fail\n' >&2
  cat "$checker_json" >&2
  exit 1
fi

timeout 30 "$claspc_bin" --json check "$unknown_name_source" >"$unknown_name_json" 2>"$test_root/unknown-name.stderr" || unknown_name_json_status=$?
unknown_name_json_status="${unknown_name_json_status:-0}"
if [[ "$unknown_name_json_status" == "0" ]]; then
  printf 'expected unknown-name json check to fail\n' >&2
  cat "$unknown_name_json" >&2
  exit 1
fi

timeout 30 "$claspc_bin" --json check "$valid_multiline_source" >"$valid_multiline_json" 2>"$test_root/valid-multiline.stderr" || valid_multiline_status=$?
valid_multiline_status="${valid_multiline_status:-0}"
if [[ "$valid_multiline_status" != "0" ]]; then
  printf 'expected valid multiline rhs check to pass\n' >&2
  cat "$valid_multiline_json" >&2
  cat "$test_root/valid-multiline.stderr" >&2
  exit 1
fi

timeout 30 "$claspc_bin" --json check "$project_root/examples/polymorphism/Main.clasp" >"$polymorphism_json" 2>"$test_root/polymorphism.stderr" || polymorphism_status=$?
polymorphism_status="${polymorphism_status:-0}"
if [[ "$polymorphism_status" != "0" ]]; then
  printf 'expected polymorphism example check to pass\n' >&2
  cat "$polymorphism_json" >&2
  cat "$test_root/polymorphism.stderr" >&2
  exit 1
fi

expect_failure "$parser_pretty" timeout 30 "$claspc_bin" check "$parser_source"
expect_failure "$checker_pretty" timeout 30 "$claspc_bin" check "$checker_source"
expect_failure "$unknown_name_pretty" timeout 30 "$claspc_bin" check "$unknown_name_source"

node - "$parser_json" "$checker_json" "$unknown_name_json" "$valid_multiline_json" "$polymorphism_json" "$parser_source" "$checker_source" "$unknown_name_source" "$valid_multiline_source" "$project_root/examples/polymorphism/Main.clasp" <<'NODE'
const fs = require("node:fs");

const [
  parserJsonPath,
  checkerJsonPath,
  unknownNameJsonPath,
  validMultilineJsonPath,
  polymorphismJsonPath,
  parserSource,
  checkerSource,
  unknownNameSource,
  validMultilineSource,
  polymorphismSource,
] = process.argv.slice(2);
const parser = JSON.parse(fs.readFileSync(parserJsonPath, "utf8"));
const checker = JSON.parse(fs.readFileSync(checkerJsonPath, "utf8"));
const unknownName = JSON.parse(fs.readFileSync(unknownNameJsonPath, "utf8"));
const validMultiline = JSON.parse(fs.readFileSync(validMultilineJsonPath, "utf8"));
const polymorphism = JSON.parse(fs.readFileSync(polymorphismJsonPath, "utf8"));

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function firstDiagnostic(report, label) {
  assert(report.status === "error", `${label}: expected error status`);
  assert(report.implementation === "clasp-native", `${label}: expected native implementation`);
  assert(Array.isArray(report.diagnostics), `${label}: expected diagnostics array`);
  assert(report.diagnostics.length === 1, `${label}: expected one diagnostic`);
  const diagnostic = report.diagnostics[0];
  assert(typeof diagnostic.message === "string" && diagnostic.message.length > 0, `${label}: expected message`);
  assert(diagnostic.primarySpan && typeof diagnostic.primarySpan === "object", `${label}: expected primarySpan`);
  return diagnostic;
}

const parserDiagnostic = firstDiagnostic(parser, "parser");
assert(parserDiagnostic.phase === "parser", `parser phase: ${parserDiagnostic.phase}`);
assert(parserDiagnostic.code === "E_PARSE_EMPTY_EXPRESSION", `parser code: ${parserDiagnostic.code}`);
assert(parserDiagnostic.file === parserSource, `parser file: ${parserDiagnostic.file}`);
assert(parserDiagnostic.line === 3, `parser line: ${parserDiagnostic.line}`);
assert(parserDiagnostic.column === 7, `parser column: ${parserDiagnostic.column}`);
assert(parserDiagnostic.expected === "expression", `parser expected: ${parserDiagnostic.expected}`);
assert(parserDiagnostic.actual === "end of line", `parser actual: ${parserDiagnostic.actual}`);
assert(parserDiagnostic.primarySpan.start.line === 3, "parser span line");
assert(parserDiagnostic.primarySpan.start.column === 7, "parser span column");

const checkerDiagnostic = firstDiagnostic(checker, "checker");
assert(checkerDiagnostic.phase === "checker", `checker phase: ${checkerDiagnostic.phase}`);
assert(checkerDiagnostic.code === "E_TYPE_MISMATCH", `checker code: ${checkerDiagnostic.code}`);
assert(checkerDiagnostic.file === checkerSource, `checker file: ${checkerDiagnostic.file}`);
assert(checkerDiagnostic.line === 4, `checker line: ${checkerDiagnostic.line}`);
assert(checkerDiagnostic.column === 8, `checker column: ${checkerDiagnostic.column}`);
assert(checkerDiagnostic.context === "main", `checker context: ${checkerDiagnostic.context}`);
assert(checkerDiagnostic.target === "1", `checker target: ${checkerDiagnostic.target}`);
assert(checkerDiagnostic.expected === "Str", `checker expected: ${checkerDiagnostic.expected}`);
assert(checkerDiagnostic.actual === "Int", `checker actual: ${checkerDiagnostic.actual}`);
assert(
  checkerDiagnostic.message.includes("expected Str, found Int"),
  `checker message: ${checkerDiagnostic.message}`,
);

const unknownNameDiagnostic = firstDiagnostic(unknownName, "unknown-name");
assert(unknownNameDiagnostic.phase === "checker", `unknown-name phase: ${unknownNameDiagnostic.phase}`);
assert(unknownNameDiagnostic.code === "E_UNBOUND_NAME", `unknown-name code: ${unknownNameDiagnostic.code}`);
assert(unknownNameDiagnostic.file === unknownNameSource, `unknown-name file: ${unknownNameDiagnostic.file}`);
assert(unknownNameDiagnostic.line === 7, `unknown-name line: ${unknownNameDiagnostic.line}`);
assert(unknownNameDiagnostic.column === 8, `unknown-name column: ${unknownNameDiagnostic.column}`);
assert(unknownNameDiagnostic.context === "main", `unknown-name context: ${unknownNameDiagnostic.context}`);
assert(unknownNameDiagnostic.target === "renderNmae", `unknown-name target: ${unknownNameDiagnostic.target}`);
assert(Array.isArray(unknownNameDiagnostic.candidates), "unknown-name candidates should be an array");
assert(
  unknownNameDiagnostic.candidates.includes("renderName"),
  `unknown-name candidates: ${JSON.stringify(unknownNameDiagnostic.candidates)}`,
);
assert(
  unknownNameDiagnostic.message.includes("Did you mean `renderName`?"),
  `unknown-name message: ${unknownNameDiagnostic.message}`,
);

assert(validMultiline.status === "ok", `valid multiline status: ${validMultiline.status}`);
assert(validMultiline.input === validMultilineSource, `valid multiline input: ${validMultiline.input}`);
assert(!Array.isArray(validMultiline.diagnostics), "valid multiline should not report diagnostics");

assert(polymorphism.status === "ok", `polymorphism status: ${polymorphism.status}`);
assert(polymorphism.input === polymorphismSource, `polymorphism input: ${polymorphism.input}`);
assert(!Array.isArray(polymorphism.diagnostics), "polymorphism should not report diagnostics");
NODE

grep -F 'CLASP_DIAGNOSTIC phase=parser code=E_PARSE_EMPTY_EXPRESSION' "$parser_pretty" >/dev/null
grep -F 'line=3 column=7' "$parser_pretty" >/dev/null
grep -F 'expected="expression" actual="end of line"' "$parser_pretty" >/dev/null
grep -F 'CLASP_DIAGNOSTIC phase=checker code=E_TYPE_MISMATCH' "$checker_pretty" >/dev/null
grep -F 'line=4 column=8' "$checker_pretty" >/dev/null
grep -F 'context="main" target="1" expected="Str" actual="Int"' "$checker_pretty" >/dev/null
grep -F 'CLASP_DIAGNOSTIC phase=checker code=E_UNBOUND_NAME' "$unknown_name_pretty" >/dev/null
grep -F 'line=7 column=8' "$unknown_name_pretty" >/dev/null
grep -F 'context="main" target="renderNmae"' "$unknown_name_pretty" >/dev/null
grep -F 'candidates="renderName"' "$unknown_name_pretty" >/dev/null
grep -F 'Did you mean `renderName`?' "$unknown_name_pretty" >/dev/null

printf 'test-native-claspc-diagnostics: ok\n'
