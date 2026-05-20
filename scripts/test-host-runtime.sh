#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-host-runtime.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

claspc_bin="$(
  CLASP_CLASPC= CLASPC_BIN= CLASP_PROJECT_ROOT="$project_root" \
    "$project_root/scripts/resolve-claspc.sh"
)"
state_root="$test_root/state"
output_path="$test_root/host-runtime-output.json"

CLASP_HOST_RUNTIME_SCENARIO_ENV=parent-env \
  timeout 120 "$claspc_bin" run "$project_root/examples/host-runtime/Main.clasp" -- "$state_root" \
  >"$output_path"

node - "$output_path" "$state_root" <<'EOF'
const fs = require("node:fs");
const path = require("node:path");

const [outputPath, stateRoot] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(outputPath, "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(typeof report.cwd === "string" && report.cwd.length > 0, "expected current working directory");
assert(report.parentEnv === "parent-env", "parent env lookup did not round-trip");
assert(report.fileText === "file-text", "readFile did not read the written input file");
assert(report.writeBack === "child-env:missing:file-text", "writeFile did not persist process stdout");
assert(report.exitCode === 0, `unexpected process exit code ${report.exitCode}`);
assert(report.stdout === "child-env:missing:file-text", "process stdout did not include cwd file and isolated child env");
assert(report.stderr === "err-child-env", "process stderr did not include child env");
assert(report.parentChildEnv === "ERR:missing", "child env leaked into the parent runtime");
assert(
  fs.readFileSync(path.join(stateRoot, "output.txt"), "utf8") === "child-env:missing:file-text",
  "persisted output file mismatch",
);
EOF

printf '%s\n' "host-runtime-ok"
