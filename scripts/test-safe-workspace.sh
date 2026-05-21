#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_SAFE_WORKSPACE_TIMEOUT_SECS:-120}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_SAFE_WORKSPACE_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-safe-workspace.XXXXXX")"
workspace_root="$test_root/workspace"
outside_path="$test_root/outside.txt"
output_path="$test_root/output.json"

cleanup() {
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root" >&2
  else
    rm -rf "$test_root" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

mkdir -p "$workspace_root"
printf 'outside-secret' > "$outside_path"

claspc_bin="$(
  CLASP_CLASPC= CLASPC_BIN= CLASP_PROJECT_ROOT="$project_root" \
    "$project_root/scripts/resolve-claspc.sh"
)"
demo_path="$project_root/examples/safe-workspace/Main.clasp"

timeout "$timeout_secs" "$claspc_bin" --json check "$demo_path" | grep -F '"status":"ok"' >/dev/null
timeout "$timeout_secs" "$claspc_bin" run "$demo_path" -- "$workspace_root" "$outside_path" >"$output_path"

node - "$output_path" "$workspace_root" "$outside_path" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const [outputPath, workspaceRoot, outsidePath] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(outputPath, "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function startsWith(value, prefix, label) {
  assert(typeof value === "string" && value.startsWith(prefix), `${label} expected prefix ${prefix}, got ${value}`);
}

assert(report.normalizedPath.endsWith(path.join("nested", "result.txt")), "normalized path should stay below workspace root");
assert(report.mkdirResult.endsWith(path.join("logs")), "mkdirAll should return the created workspace path");
assert(report.writeResult.endsWith(path.join("nested", "result.txt")), "writeFile should return the written workspace path");
assert(report.appendResult.endsWith(path.join("logs", "events.jsonl")), "appendFile should return the appended workspace path");
assert(report.readText === "workspace-text", "read-back text should match");
assert(report.appendedText === "event-one\nevent-two\n", "appendFile should preserve ordered JSONL-style appends");
assert(report.nestedListing === "result.txt", "nested listing should expose the written file");
assert(report.rootListing.split(",").includes("logs"), "root listing should include logs");
assert(report.rootListing.split(",").includes("nested"), "root listing should include nested");
startsWith(report.parentEscape, "ERR:workspace_path_escape", "parent escape");
startsWith(report.absoluteEscape, "ERR:workspace_path_escape", "absolute escape");
assert(report.absoluteEscape.includes("absolute paths are not allowed"), "absolute escape should explain the relative-path contract");
startsWith(report.chainedEscape, "ERR:workspace_path_escape", "chained escape");
startsWith(report.missingRead, "ERR:workspace_missing", "missing read");

assert(
  fs.readFileSync(path.join(workspaceRoot, "nested", "result.txt"), "utf8") === "workspace-text",
  "workspace write should persist inside the root",
);
assert(
  fs.readFileSync(path.join(workspaceRoot, "logs", "events.jsonl"), "utf8") === "event-one\nevent-two\n",
  "workspace append should persist inside the root",
);
assert(fs.readFileSync(outsidePath, "utf8") === "outside-secret", "absolute-path write attempt should not touch outside file");
NODE

printf '%s\n' "safe-workspace-ok"
