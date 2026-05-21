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
record_missing_source="$test_root/checker-record-missing-field.clasp"
record_unknown_source="$test_root/checker-record-unknown-field.clasp"
record_duplicate_source="$test_root/checker-record-duplicate-field.clasp"
record_valid_source="$test_root/checker-record-valid-fields.clasp"
record_multiline_source="$test_root/checker-record-valid-multiline-fields.clasp"
record_multiline_duplicate_source="$test_root/checker-record-duplicate-multiline-field.clasp"
record_update_duplicate_source="$test_root/checker-record-update-duplicate-field.clasp"
record_update_valid_source="$test_root/checker-record-update-valid-field.clasp"
record_colon_source="$test_root/parser-record-field-colon.clasp"
valid_multiline_source="$test_root/parser-valid-multiline-rhs.clasp"
parser_json="$test_root/parser.json"
parser_pretty="$test_root/parser.pretty"
checker_json="$test_root/checker.json"
checker_pretty="$test_root/checker.pretty"
unknown_name_json="$test_root/checker-unknown-name.json"
unknown_name_pretty="$test_root/checker-unknown-name.pretty"
record_missing_json="$test_root/checker-record-missing-field.json"
record_missing_pretty="$test_root/checker-record-missing-field.pretty"
record_unknown_json="$test_root/checker-record-unknown-field.json"
record_unknown_pretty="$test_root/checker-record-unknown-field.pretty"
record_duplicate_json="$test_root/checker-record-duplicate-field.json"
record_duplicate_pretty="$test_root/checker-record-duplicate-field.pretty"
record_valid_json="$test_root/checker-record-valid-fields.json"
record_multiline_json="$test_root/checker-record-valid-multiline-fields.json"
record_multiline_duplicate_json="$test_root/checker-record-duplicate-multiline-field.json"
record_multiline_duplicate_pretty="$test_root/checker-record-duplicate-multiline-field.pretty"
record_update_duplicate_json="$test_root/checker-record-update-duplicate-field.json"
record_update_duplicate_pretty="$test_root/checker-record-update-duplicate-field.pretty"
record_update_valid_json="$test_root/checker-record-update-valid-field.json"
record_colon_json="$test_root/parser-record-field-colon.json"
record_colon_pretty="$test_root/parser-record-field-colon.pretty"
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

cat >"$record_missing_source" <<'EOF'
module Main

record User = { name : Str, active : Bool }

main = User { name = "Ada" }
EOF

cat >"$record_unknown_source" <<'EOF'
module Main

record User = { name : Str, active : Bool }

main = User { name = "Ada", enabled = true, active = true }
EOF

cat >"$record_duplicate_source" <<'EOF'
module Main

record User = { name : Str, active : Bool }

main = User { name = "Ada", name = "Grace", active = true }
EOF

cat >"$record_valid_source" <<'EOF'
module Main

record User = { name : Str, active : Bool }

main = User { name = "Ada", active = true }
EOF

cat >"$record_multiline_source" <<'EOF'
module Main

record User = { name : Str, active : Bool }

main =
  User {
    name = "Ada",
    active = true
  }
EOF

cat >"$record_multiline_duplicate_source" <<'EOF'
module Main

record User = { name : Str, active : Bool }

main =
  User {
    name = "Ada",
    name = "Grace",
    active = true
  }
EOF

cat >"$record_update_duplicate_source" <<'EOF'
module Main

record User = { name : Str, active : Bool }

seed = User { name = "Ada", active = true }
main = with seed { name = "Grace", name = "Ada" }
EOF

cat >"$record_update_valid_source" <<'EOF'
module Main

record User = { name : Str, active : Bool }

seed = User { name = "Ada", active = true }
main = with seed { name = "Grace" }
EOF

cat >"$record_colon_source" <<'EOF'
module Main

record User = { name : Str }

main = User { name: "Ada" }
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

timeout 30 "$claspc_bin" --json check "$record_missing_source" >"$record_missing_json" 2>"$test_root/record-missing.stderr" || record_missing_json_status=$?
record_missing_json_status="${record_missing_json_status:-0}"
if [[ "$record_missing_json_status" == "0" ]]; then
  printf 'expected record-missing json check to fail\n' >&2
  cat "$record_missing_json" >&2
  exit 1
fi

timeout 30 "$claspc_bin" --json check "$record_unknown_source" >"$record_unknown_json" 2>"$test_root/record-unknown.stderr" || record_unknown_json_status=$?
record_unknown_json_status="${record_unknown_json_status:-0}"
if [[ "$record_unknown_json_status" == "0" ]]; then
  printf 'expected record-unknown json check to fail\n' >&2
  cat "$record_unknown_json" >&2
  exit 1
fi

timeout 30 "$claspc_bin" --json check "$record_duplicate_source" >"$record_duplicate_json" 2>"$test_root/record-duplicate.stderr" || record_duplicate_json_status=$?
record_duplicate_json_status="${record_duplicate_json_status:-0}"
if [[ "$record_duplicate_json_status" == "0" ]]; then
  printf 'expected record-duplicate json check to fail\n' >&2
  cat "$record_duplicate_json" >&2
  exit 1
fi

timeout 30 "$claspc_bin" --json check "$record_valid_source" >"$record_valid_json" 2>"$test_root/record-valid.stderr" || record_valid_status=$?
record_valid_status="${record_valid_status:-0}"
if [[ "$record_valid_status" != "0" ]]; then
  printf 'expected valid record literal check to pass\n' >&2
  cat "$record_valid_json" >&2
  cat "$test_root/record-valid.stderr" >&2
  exit 1
fi

timeout 30 "$claspc_bin" --json check "$record_multiline_source" >"$record_multiline_json" 2>"$test_root/record-multiline.stderr" || record_multiline_status=$?
record_multiline_status="${record_multiline_status:-0}"
if [[ "$record_multiline_status" != "0" ]]; then
  printf 'expected valid multiline record literal check to pass\n' >&2
  cat "$record_multiline_json" >&2
  cat "$test_root/record-multiline.stderr" >&2
  exit 1
fi

timeout 30 "$claspc_bin" --json check "$record_multiline_duplicate_source" >"$record_multiline_duplicate_json" 2>"$test_root/record-multiline-duplicate.stderr" || record_multiline_duplicate_json_status=$?
record_multiline_duplicate_json_status="${record_multiline_duplicate_json_status:-0}"
if [[ "$record_multiline_duplicate_json_status" == "0" ]]; then
  printf 'expected record-multiline-duplicate json check to fail\n' >&2
  cat "$record_multiline_duplicate_json" >&2
  exit 1
fi

timeout 30 "$claspc_bin" --json check "$record_update_duplicate_source" >"$record_update_duplicate_json" 2>"$test_root/record-update-duplicate.stderr" || record_update_duplicate_json_status=$?
record_update_duplicate_json_status="${record_update_duplicate_json_status:-0}"
if [[ "$record_update_duplicate_json_status" == "0" ]]; then
  printf 'expected record-update-duplicate json check to fail\n' >&2
  cat "$record_update_duplicate_json" >&2
  exit 1
fi

timeout 30 "$claspc_bin" --json check "$record_update_valid_source" >"$record_update_valid_json" 2>"$test_root/record-update-valid.stderr" || record_update_valid_status=$?
record_update_valid_status="${record_update_valid_status:-0}"
if [[ "$record_update_valid_status" != "0" ]]; then
  printf 'expected valid record update check to pass\n' >&2
  cat "$record_update_valid_json" >&2
  cat "$test_root/record-update-valid.stderr" >&2
  exit 1
fi

timeout 30 "$claspc_bin" --json check "$record_colon_source" >"$record_colon_json" 2>"$test_root/record-colon.stderr" || record_colon_json_status=$?
record_colon_json_status="${record_colon_json_status:-0}"
if [[ "$record_colon_json_status" == "0" ]]; then
  printf 'expected record-colon json check to fail\n' >&2
  cat "$record_colon_json" >&2
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
expect_failure "$record_missing_pretty" timeout 30 "$claspc_bin" check "$record_missing_source"
expect_failure "$record_unknown_pretty" timeout 30 "$claspc_bin" check "$record_unknown_source"
expect_failure "$record_duplicate_pretty" timeout 30 "$claspc_bin" check "$record_duplicate_source"
expect_failure "$record_multiline_duplicate_pretty" timeout 30 "$claspc_bin" check "$record_multiline_duplicate_source"
expect_failure "$record_update_duplicate_pretty" timeout 30 "$claspc_bin" check "$record_update_duplicate_source"
expect_failure "$record_colon_pretty" timeout 30 "$claspc_bin" check "$record_colon_source"

node - "$parser_json" "$checker_json" "$unknown_name_json" "$record_missing_json" "$record_unknown_json" "$record_duplicate_json" "$record_valid_json" "$record_multiline_json" "$record_multiline_duplicate_json" "$record_update_duplicate_json" "$record_update_valid_json" "$record_colon_json" "$valid_multiline_json" "$polymorphism_json" "$parser_source" "$checker_source" "$unknown_name_source" "$record_missing_source" "$record_unknown_source" "$record_duplicate_source" "$record_valid_source" "$record_multiline_source" "$record_multiline_duplicate_source" "$record_update_duplicate_source" "$record_update_valid_source" "$record_colon_source" "$valid_multiline_source" "$project_root/examples/polymorphism/Main.clasp" <<'NODE'
const fs = require("node:fs");

const [
  parserJsonPath,
  checkerJsonPath,
  unknownNameJsonPath,
  recordMissingJsonPath,
  recordUnknownJsonPath,
  recordDuplicateJsonPath,
  recordValidJsonPath,
  recordMultilineJsonPath,
  recordMultilineDuplicateJsonPath,
  recordUpdateDuplicateJsonPath,
  recordUpdateValidJsonPath,
  recordColonJsonPath,
  validMultilineJsonPath,
  polymorphismJsonPath,
  parserSource,
  checkerSource,
  unknownNameSource,
  recordMissingSource,
  recordUnknownSource,
  recordDuplicateSource,
  recordValidSource,
  recordMultilineSource,
  recordMultilineDuplicateSource,
  recordUpdateDuplicateSource,
  recordUpdateValidSource,
  recordColonSource,
  validMultilineSource,
  polymorphismSource,
] = process.argv.slice(2);
const parser = JSON.parse(fs.readFileSync(parserJsonPath, "utf8"));
const checker = JSON.parse(fs.readFileSync(checkerJsonPath, "utf8"));
const unknownName = JSON.parse(fs.readFileSync(unknownNameJsonPath, "utf8"));
const recordMissing = JSON.parse(fs.readFileSync(recordMissingJsonPath, "utf8"));
const recordUnknown = JSON.parse(fs.readFileSync(recordUnknownJsonPath, "utf8"));
const recordDuplicate = JSON.parse(fs.readFileSync(recordDuplicateJsonPath, "utf8"));
const recordValid = JSON.parse(fs.readFileSync(recordValidJsonPath, "utf8"));
const recordMultiline = JSON.parse(fs.readFileSync(recordMultilineJsonPath, "utf8"));
const recordMultilineDuplicate = JSON.parse(fs.readFileSync(recordMultilineDuplicateJsonPath, "utf8"));
const recordUpdateDuplicate = JSON.parse(fs.readFileSync(recordUpdateDuplicateJsonPath, "utf8"));
const recordUpdateValid = JSON.parse(fs.readFileSync(recordUpdateValidJsonPath, "utf8"));
const recordColon = JSON.parse(fs.readFileSync(recordColonJsonPath, "utf8"));
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
assert(Array.isArray(unknownNameDiagnostic.fixHints), "unknown-name fixHints should be an array");
assert(
  unknownNameDiagnostic.fixHints.includes("Rename the reference to `renderName`, or define/import `renderNmae` if this spelling is intentional."),
  `unknown-name fixHints: ${JSON.stringify(unknownNameDiagnostic.fixHints)}`,
);
assert(
  unknownNameDiagnostic.message.includes("Did you mean `renderName`?"),
  `unknown-name message: ${unknownNameDiagnostic.message}`,
);

const recordMissingDiagnostic = firstDiagnostic(recordMissing, "record-missing");
assert(recordMissingDiagnostic.phase === "checker", `record-missing phase: ${recordMissingDiagnostic.phase}`);
assert(recordMissingDiagnostic.code === "E_RECORD_MISSING_FIELDS", `record-missing code: ${recordMissingDiagnostic.code}`);
assert(recordMissingDiagnostic.file === recordMissingSource, `record-missing file: ${recordMissingDiagnostic.file}`);
assert(recordMissingDiagnostic.line === 5, `record-missing line: ${recordMissingDiagnostic.line}`);
assert(recordMissingDiagnostic.column === 8, `record-missing column: ${recordMissingDiagnostic.column}`);
assert(recordMissingDiagnostic.context === "main", `record-missing context: ${recordMissingDiagnostic.context}`);
assert(recordMissingDiagnostic.target === "User", `record-missing target: ${recordMissingDiagnostic.target}`);
assert(recordMissingDiagnostic.expected === "active", `record-missing expected: ${recordMissingDiagnostic.expected}`);
assert(recordMissingDiagnostic.actual === "missing field", `record-missing actual: ${recordMissingDiagnostic.actual}`);
assert(
  recordMissingDiagnostic.message.includes("Record literal for `User` is missing field `active`."),
  `record-missing message: ${recordMissingDiagnostic.message}`,
);

const recordUnknownDiagnostic = firstDiagnostic(recordUnknown, "record-unknown");
assert(recordUnknownDiagnostic.phase === "checker", `record-unknown phase: ${recordUnknownDiagnostic.phase}`);
assert(recordUnknownDiagnostic.code === "E_RECORD_UNKNOWN_FIELD", `record-unknown code: ${recordUnknownDiagnostic.code}`);
assert(recordUnknownDiagnostic.file === recordUnknownSource, `record-unknown file: ${recordUnknownDiagnostic.file}`);
assert(recordUnknownDiagnostic.line === 5, `record-unknown line: ${recordUnknownDiagnostic.line}`);
assert(recordUnknownDiagnostic.column === 8, `record-unknown column: ${recordUnknownDiagnostic.column}`);
assert(recordUnknownDiagnostic.context === "main", `record-unknown context: ${recordUnknownDiagnostic.context}`);
assert(recordUnknownDiagnostic.target === "User", `record-unknown target: ${recordUnknownDiagnostic.target}`);
assert(recordUnknownDiagnostic.expected === "declared field", `record-unknown expected: ${recordUnknownDiagnostic.expected}`);
assert(recordUnknownDiagnostic.actual === "enabled", `record-unknown actual: ${recordUnknownDiagnostic.actual}`);
assert(
  recordUnknownDiagnostic.message.includes("Record literal for `User` includes unknown field `enabled`."),
  `record-unknown message: ${recordUnknownDiagnostic.message}`,
);

const recordDuplicateDiagnostic = firstDiagnostic(recordDuplicate, "record-duplicate");
assert(recordDuplicateDiagnostic.phase === "checker", `record-duplicate phase: ${recordDuplicateDiagnostic.phase}`);
assert(recordDuplicateDiagnostic.code === "E_RECORD_DUPLICATE_FIELD", `record-duplicate code: ${recordDuplicateDiagnostic.code}`);
assert(recordDuplicateDiagnostic.file === recordDuplicateSource, `record-duplicate file: ${recordDuplicateDiagnostic.file}`);
assert(recordDuplicateDiagnostic.line === 5, `record-duplicate line: ${recordDuplicateDiagnostic.line}`);
assert(recordDuplicateDiagnostic.column === 13, `record-duplicate column: ${recordDuplicateDiagnostic.column}`);
assert(recordDuplicateDiagnostic.context == null, `record-duplicate context: ${recordDuplicateDiagnostic.context}`);
assert(recordDuplicateDiagnostic.target === "User", `record-duplicate target: ${recordDuplicateDiagnostic.target}`);
assert(recordDuplicateDiagnostic.expected === "unique field", `record-duplicate expected: ${recordDuplicateDiagnostic.expected}`);
assert(recordDuplicateDiagnostic.actual === "name", `record-duplicate actual: ${recordDuplicateDiagnostic.actual}`);
assert(
  recordDuplicateDiagnostic.message.includes("Record literal for `User` repeats field `name`."),
  `record-duplicate message: ${recordDuplicateDiagnostic.message}`,
);

const recordMultilineDuplicateDiagnostic = firstDiagnostic(recordMultilineDuplicate, "record-multiline-duplicate");
assert(recordMultilineDuplicateDiagnostic.phase === "checker", `record-multiline-duplicate phase: ${recordMultilineDuplicateDiagnostic.phase}`);
assert(recordMultilineDuplicateDiagnostic.code === "E_RECORD_DUPLICATE_FIELD", `record-multiline-duplicate code: ${recordMultilineDuplicateDiagnostic.code}`);
assert(recordMultilineDuplicateDiagnostic.file === recordMultilineDuplicateSource, `record-multiline-duplicate file: ${recordMultilineDuplicateDiagnostic.file}`);
assert(recordMultilineDuplicateDiagnostic.line === 6, `record-multiline-duplicate line: ${recordMultilineDuplicateDiagnostic.line}`);
assert(recordMultilineDuplicateDiagnostic.column === 8, `record-multiline-duplicate column: ${recordMultilineDuplicateDiagnostic.column}`);
assert(recordMultilineDuplicateDiagnostic.context == null, `record-multiline-duplicate context: ${recordMultilineDuplicateDiagnostic.context}`);
assert(recordMultilineDuplicateDiagnostic.target === "User", `record-multiline-duplicate target: ${recordMultilineDuplicateDiagnostic.target}`);
assert(recordMultilineDuplicateDiagnostic.expected === "unique field", `record-multiline-duplicate expected: ${recordMultilineDuplicateDiagnostic.expected}`);
assert(recordMultilineDuplicateDiagnostic.actual === "name", `record-multiline-duplicate actual: ${recordMultilineDuplicateDiagnostic.actual}`);
assert(
  recordMultilineDuplicateDiagnostic.message.includes("Record literal for `User` repeats field `name`."),
  `record-multiline-duplicate message: ${recordMultilineDuplicateDiagnostic.message}`,
);

const recordUpdateDuplicateDiagnostic = firstDiagnostic(recordUpdateDuplicate, "record-update-duplicate");
assert(recordUpdateDuplicateDiagnostic.phase === "checker", `record-update-duplicate phase: ${recordUpdateDuplicateDiagnostic.phase}`);
assert(recordUpdateDuplicateDiagnostic.code === "E_RECORD_DUPLICATE_FIELD", `record-update-duplicate code: ${recordUpdateDuplicateDiagnostic.code}`);
assert(recordUpdateDuplicateDiagnostic.file === recordUpdateDuplicateSource, `record-update-duplicate file: ${recordUpdateDuplicateDiagnostic.file}`);
assert(recordUpdateDuplicateDiagnostic.line === 6, `record-update-duplicate line: ${recordUpdateDuplicateDiagnostic.line}`);
assert(recordUpdateDuplicateDiagnostic.column === 8, `record-update-duplicate column: ${recordUpdateDuplicateDiagnostic.column}`);
assert(recordUpdateDuplicateDiagnostic.context == null, `record-update-duplicate context: ${recordUpdateDuplicateDiagnostic.context}`);
assert(recordUpdateDuplicateDiagnostic.target === "record update", `record-update-duplicate target: ${recordUpdateDuplicateDiagnostic.target}`);
assert(recordUpdateDuplicateDiagnostic.expected === "unique field", `record-update-duplicate expected: ${recordUpdateDuplicateDiagnostic.expected}`);
assert(recordUpdateDuplicateDiagnostic.actual === "name", `record-update-duplicate actual: ${recordUpdateDuplicateDiagnostic.actual}`);
assert(
  recordUpdateDuplicateDiagnostic.message.includes("Record update repeats field `name`."),
  `record-update-duplicate message: ${recordUpdateDuplicateDiagnostic.message}`,
);

const recordColonDiagnostic = firstDiagnostic(recordColon, "record-colon");
assert(recordColonDiagnostic.phase === "parser", `record-colon phase: ${recordColonDiagnostic.phase}`);
assert(recordColonDiagnostic.code === "E_PARSE_RECORD_FIELD_SEPARATOR", `record-colon code: ${recordColonDiagnostic.code}`);
assert(recordColonDiagnostic.file === recordColonSource, `record-colon file: ${recordColonDiagnostic.file}`);
assert(recordColonDiagnostic.line === 5, `record-colon line: ${recordColonDiagnostic.line}`);
assert(recordColonDiagnostic.column === 19, `record-colon column: ${recordColonDiagnostic.column}`);
assert(recordColonDiagnostic.target === "name", `record-colon target: ${recordColonDiagnostic.target}`);
assert(recordColonDiagnostic.expected === "field = expression", `record-colon expected: ${recordColonDiagnostic.expected}`);
assert(recordColonDiagnostic.actual === "field: expression", `record-colon actual: ${recordColonDiagnostic.actual}`);
assert(
  recordColonDiagnostic.message.includes("Use `name = <expression>` inside record literals."),
  `record-colon message: ${recordColonDiagnostic.message}`,
);

assert(recordValid.status === "ok", `record valid status: ${recordValid.status}`);
assert(recordValid.input === recordValidSource, `record valid input: ${recordValid.input}`);
assert(!Array.isArray(recordValid.diagnostics), "valid record literal should not report diagnostics");

assert(recordMultiline.status === "ok", `record multiline status: ${recordMultiline.status}`);
assert(recordMultiline.input === recordMultilineSource, `record multiline input: ${recordMultiline.input}`);
assert(!Array.isArray(recordMultiline.diagnostics), "valid multiline record literal should not report diagnostics");

assert(recordUpdateValid.status === "ok", `record update valid status: ${recordUpdateValid.status}`);
assert(recordUpdateValid.input === recordUpdateValidSource, `record update valid input: ${recordUpdateValid.input}`);
assert(!Array.isArray(recordUpdateValid.diagnostics), "valid record update should not report diagnostics");

assert(validMultiline.status === "ok", `valid multiline status: ${validMultiline.status}`);
assert(validMultiline.input === validMultilineSource, `valid multiline input: ${validMultiline.input}`);
assert(!Array.isArray(validMultiline.diagnostics), "valid multiline should not report diagnostics");

assert(polymorphism.status === "ok", `polymorphism status: ${polymorphism.status}`);
assert(polymorphism.input === polymorphismSource, `polymorphism input: ${polymorphism.input}`);
assert(!Array.isArray(polymorphism.diagnostics), "polymorphism should not report diagnostics");
NODE

for pretty_output in \
  "$parser_pretty" \
  "$checker_pretty" \
  "$unknown_name_pretty" \
  "$record_missing_pretty" \
  "$record_unknown_pretty" \
  "$record_duplicate_pretty" \
  "$record_multiline_duplicate_pretty" \
  "$record_update_duplicate_pretty" \
  "$record_colon_pretty"
do
  if grep -F 'CLASP_DIAGNOSTIC' "$pretty_output" >/dev/null; then
    printf 'default human output leaked machine diagnostic prefix: %s\n' "$pretty_output" >&2
    cat "$pretty_output" >&2
    exit 1
  fi
  if grep -F '"diagnostics"' "$pretty_output" >/dev/null; then
    printf 'default human output leaked JSON diagnostics: %s\n' "$pretty_output" >&2
    cat "$pretty_output" >&2
    exit 1
  fi
done

grep -F 'Missing expression after `=`.' "$parser_pretty" >/dev/null
grep -F 'In `main`: Type mismatch for `1`: expected Str, found Int.' "$checker_pretty" >/dev/null
grep -F 'Did you mean `renderName`?' "$unknown_name_pretty" >/dev/null
grep -F 'Record literal for `User` is missing field `active`.' "$record_missing_pretty" >/dev/null
grep -F 'Record literal for `User` includes unknown field `enabled`.' "$record_unknown_pretty" >/dev/null
grep -F 'Record literal for `User` repeats field `name`.' "$record_duplicate_pretty" >/dev/null
grep -F 'Record literal for `User` repeats field `name`.' "$record_multiline_duplicate_pretty" >/dev/null
grep -F 'Record update repeats field `name`.' "$record_update_duplicate_pretty" >/dev/null
grep -F 'Use `name = <expression>` inside record literals.' "$record_colon_pretty" >/dev/null

printf 'test-native-claspc-diagnostics: ok\n'
