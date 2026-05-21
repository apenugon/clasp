#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_SAFE_SUBPROCESS_TIMEOUT_SECS:-120}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_SAFE_SUBPROCESS_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-safe-subprocess.XXXXXX")"
workspace_root="$test_root/workspace"
outside_root="$test_root/outside"
output_path="$test_root/output.json"

cleanup() {
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root" >&2
  else
    rm -rf "$test_root" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

mkdir -p "$workspace_root/work" "$outside_root"

claspc_bin="$(
  CLASP_CLASPC= CLASPC_BIN= CLASP_PROJECT_ROOT="$project_root" \
    "$project_root/scripts/resolve-claspc.sh"
)"
demo_path="$project_root/examples/safe-subprocess/Main.clasp"

timeout "$timeout_secs" "$claspc_bin" --json check "$demo_path" | grep -F '"status":"ok"' >/dev/null
timeout "$timeout_secs" "$claspc_bin" run "$demo_path" -- "$workspace_root" "$outside_root" >"$output_path"

node - "$output_path" <<'NODE'
const fs = require("node:fs");

const [outputPath] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(outputPath, "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function startsWith(value, prefix, label) {
  assert(typeof value === "string" && value.startsWith(prefix), `${label} expected prefix ${prefix}, got ${value}`);
}

assert(report.successExitCode === 0, `unexpected success exit ${report.successExitCode}`);
assert(report.successStdout === "success-out", `unexpected success stdout ${JSON.stringify(report.successStdout)}`);
assert(report.successStderr === "success-err", `unexpected success stderr ${JSON.stringify(report.successStderr)}`);

assert(report.nonzeroExitCode === 7, `unexpected nonzero exit ${report.nonzeroExitCode}`);
assert(report.nonzeroStdout === "nonzero-out", `unexpected nonzero stdout ${JSON.stringify(report.nonzeroStdout)}`);
assert(report.nonzeroStderr === "nonzero-err", `unexpected nonzero stderr ${JSON.stringify(report.nonzeroStderr)}`);

assert(report.timeoutExitCode === 124, `unexpected timeout exit ${report.timeoutExitCode}`);
assert(report.timeoutStdout === "before-timeout", `unexpected timeout stdout ${JSON.stringify(report.timeoutStdout)}`);
assert(report.timeoutStderr === "", `unexpected timeout stderr ${JSON.stringify(report.timeoutStderr)}`);
assert(report.timeoutTimedOut === true, "timeout should set timedOut");
assert(report.timeoutError === "timeout", `unexpected timeout error ${JSON.stringify(report.timeoutError)}`);

startsWith(report.missingCwd, "ERR:workspace_missing", "missing cwd");
startsWith(report.parentEscape, "ERR:workspace_path_escape", "parent cwd escape");
startsWith(report.absoluteCwd, "ERR:workspace_path_escape", "absolute cwd escape");
assert(report.absoluteCwd.includes("absolute paths are not allowed"), "absolute cwd escape should explain relative cwd contract");
startsWith(report.shellString, "ERR:process_shell_string_rejected", "shell string command");
NODE

printf '%s\n' "safe-subprocess-ok"
