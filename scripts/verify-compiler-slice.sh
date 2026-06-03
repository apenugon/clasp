#!/usr/bin/env bash
set -euo pipefail

ulimit -c 0 >/dev/null 2>&1 || true

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
timeout_secs="${CLASP_COMPILER_SLICE_TIMEOUT_SECS:-60}"
check_only=0
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
test_root=""

usage() {
  cat <<'EOF'
usage: scripts/verify-compiler-slice.sh [--list] [--check-only] [parser|checker|lower|emitter|ergonomics|all ...]

Runs a focused compiler-fixture verifier for fast local feedback before the
broader verify-all path. Each selected slice runs:
  - claspc --json check examples/compiler-<slice>.clasp
  - claspc run examples/compiler-<slice>.clasp
  - JSON assertions over the expected fixture output

Use --check-only for the cheaper syntax/type/summary gate when run-output
coverage is provided elsewhere in the current verification plan.

Environment:
  CLASP_COMPILER_SLICE_TIMEOUT_SECS  Per-claspc-command timeout in seconds (default: 60).
  CLASP_CLASPC or CLASPC_BIN         Optional explicit claspc binary.

Examples:
  bash scripts/verify-compiler-slice.sh checker
  bash scripts/verify-compiler-slice.sh --check-only checker
  bash scripts/verify-compiler-slice.sh parser lower emitter
  bash scripts/verify-compiler-slice.sh ergonomics
  CLASP_COMPILER_SLICE_TIMEOUT_SECS=30 bash scripts/verify-compiler-slice.sh all
EOF
}

list_slices() {
  printf '%s\n' parser checker lower emitter ergonomics
}

fail() {
  printf 'verify-compiler-slice: %s\n' "$*" >&2
  exit 1
}

parse_positive_timeout() {
  if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
    fail "CLASP_COMPILER_SLICE_TIMEOUT_SECS must be a positive integer"
  fi
}

resolve_claspc() {
  "$project_root/scripts/resolve-claspc.sh"
}

cleanup() {
  rm -rf "${test_root:-}"
}

assert_fixture_check_output() {
  local slice="$1"
  local check_output="$2"

  node - "$slice" "$check_output" <<'NODE'
const fs = require("node:fs");

const [slice, checkPath] = process.argv.slice(2);
const check = JSON.parse(fs.readFileSync(checkPath, "utf8"));

function assert(condition, message) {
  if (!condition) {
    throw new Error(`${slice}: ${message}`);
  }
}

assert(check.status === "ok", `expected check status ok, got ${check.status}`);
assert(check.implementation === "clasp-native", `expected clasp-native implementation, got ${check.implementation}`);

switch (slice) {
  case "parser":
    assert(
      String(check.summary || "").includes("parseModuleSummary : Str -> ParserState"),
      "check summary should include parseModuleSummary",
    );
    break;
  case "checker":
    assert(
      String(check.summary || "").includes("snapshot : CheckSnapshot"),
      "check summary should include checker snapshot",
    );
    break;
  case "lower":
    assert(
      String(check.summary || "").includes("lowerExpr : CheckedExprText -> LowerExprText"),
      "check summary should include lowerExpr",
    );
    break;
  case "emitter":
    assert(
      String(check.summary || "").includes("emitModule : [LowerDeclText] -> Str"),
      "check summary should include emitModule",
    );
    break;
  case "ergonomics":
    assert(
      String(check.summary || "").includes("snapshot : ErgonomicsSnapshot"),
      "check summary should include ergonomics snapshot",
    );
    break;
  default:
    throw new Error(`unknown slice ${slice}`);
}
NODE
}

assert_fixture_run_output() {
  local slice="$1"
  local run_output="$2"

  node - "$slice" "$run_output" <<'NODE'
const fs = require("node:fs");

const [slice, runPath] = process.argv.slice(2);
const output = JSON.parse(fs.readFileSync(runPath, "utf8"));

function assert(condition, message) {
  if (!condition) {
    throw new Error(`${slice}: ${message}`);
  }
}

switch (slice) {
  case "parser":
    assert(output.moduleName === "Compiler.Parser", `unexpected moduleName ${output.moduleName}`);
    assert(output.imports === "|Compiler.Loader|Compiler.Renderers", "parser imports summary changed");
    assert(output.signatures === "|parseModule : Str -> Str|main : Str", "parser signature summary changed");
    assert(output.declarations === "|parseModule source|main", "parser declaration summary changed");
    break;
  case "checker":
    assert(output.roster === "ok:[Str]", "checker roster inference changed");
    assert(output.matrix === "ok:[[Int]]", "checker matrix inference changed");
    assert(output.mixed === "error:expected Str but found Int", "checker mismatch diagnostic changed");
    assert(output.nestedPattern === "accepted:Ada|rejected|none", "checker nested constructor pattern changed");
    assert(output.wildcardPattern === "any", "checker wildcard pattern changed");
    break;
  case "lower":
    assert(output.listExpr === "list:[literal:Ada, literal:Grace]", "lower list expression changed");
    assert(
      output.letExpr === "let names = list:[literal:Ada, literal:Grace] in call renderNames(name:names)",
      "lower let expression changed",
    );
    assert(output.callExpr === "call score(int:7, name:weight)", "lower call expression changed");
    break;
  case "emitter":
    assert(output.arrayLiteral === "[\"Ada\", \"Grace\", \"Linus\"]", "emitter array literal changed");
    assert(
      String(output.moduleText || "").includes("export const names = [\"Ada\", \"Grace\", \"Linus\"];"),
      "emitter module text missing const output",
    );
    assert(
      String(output.moduleText || "").includes("export function renderNames(names) { return JSON.stringify(names); }"),
      "emitter module text missing function output",
    );
    break;
  case "ergonomics":
    assert(output.selectedId === "repair", `unexpected selectedId ${output.selectedId}`);
    assert(output.selectedStatus === "running", `unexpected selectedStatus ${output.selectedStatus}`);
    assert(output.statusLookup === "running", `unexpected statusLookup ${output.statusLookup}`);
    assert(output.queueCount === 1, `unexpected queueCount ${output.queueCount}`);
    assert(output.blockerCount === 0, `unexpected blockerCount ${output.blockerCount}`);
    assert(output.boxValue === "running", `unexpected boxValue ${output.boxValue}`);
    assert(output.loopSummary === "alpha!,beta!", `unexpected loopSummary ${output.loopSummary}`);
    assert(output.summary === "repair:running:running:unblocked", `unexpected summary ${output.summary}`);
    break;
  default:
    throw new Error(`unknown slice ${slice}`);
}
NODE
}

run_slice() {
  local slice="$1"
  local entry="examples/compiler-${slice}.clasp"
  local check_output="$test_root/${slice}.check.json"
  local run_output="$test_root/${slice}.run.json"

  case "$slice" in
    parser|checker|lower|emitter|ergonomics)
      ;;
    *)
      fail "unknown compiler slice: $slice"
      ;;
  esac

  printf 'verify-compiler-slice: %s check\n' "$slice"
  (
    cd "$project_root"
    timeout "$timeout_secs" "$claspc_bin" --json check "$entry" >"$check_output"
  )
  assert_fixture_check_output "$slice" "$check_output"

  if [[ "$check_only" == "1" ]]; then
    return 0
  fi

  printf 'verify-compiler-slice: %s run\n' "$slice"
  (
    cd "$project_root"
    timeout "$timeout_secs" "$claspc_bin" run "$entry" >"$run_output"
  )
  assert_fixture_run_output "$slice" "$run_output"
}

slices=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --list)
      list_slices
      exit 0
      ;;
    --check-only)
      check_only=1
      ;;
    all)
      slices=(parser checker lower emitter ergonomics)
      ;;
    parser|checker|lower|emitter|ergonomics)
      slices+=("$1")
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
  shift
done

if [[ "${#slices[@]}" == "0" ]]; then
  slices=(parser checker lower emitter ergonomics)
fi

parse_positive_timeout
mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/verify-compiler-slice.XXXXXX")"
trap cleanup EXIT

claspc_bin="$(resolve_claspc)"

for slice in "${slices[@]}"; do
  run_slice "$slice"
done

if [[ "$check_only" == "1" ]]; then
  printf 'verify-compiler-slice: ok (%s, check-only)\n' "${slices[*]}"
else
  printf 'verify-compiler-slice: ok (%s)\n' "${slices[*]}"
fi
