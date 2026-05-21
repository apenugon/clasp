#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_AGENT_SCENARIO_TIMEOUT_SECS:-60}"
test_root=""

fail() {
  printf 'agent-task-scenario verify: %s\n' "$*" >&2
  exit 1
}

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  fail "CLASP_AGENT_SCENARIO_TIMEOUT_SECS must be a positive integer"
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/agent-task-scenario.XXXXXX")"

cleanup() {
  rm -rf "${test_root:-}"
}

trap cleanup EXIT

claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
check_output="$test_root/check.json"
run_output="$test_root/run.json"
compiled_js="$test_root/Main.mjs"

(
  cd "$project_root"
  timeout "$timeout_secs" "$claspc_bin" --json check examples/agent-task-scenario/Main.clasp >"$check_output"
  timeout "$timeout_secs" "$claspc_bin" run examples/agent-task-scenario/Main.clasp >"$run_output"
  timeout "$timeout_secs" "$claspc_bin" compile examples/agent-task-scenario/Main.clasp -o "$compiled_js" >/dev/null
)

node - "$check_output" "$run_output" "$compiled_js" <<'NODE'
const fs = require("node:fs");
const { pathToFileURL } = require("node:url");

const [checkPath, runPath, compiledPath] = process.argv.slice(2);
const check = JSON.parse(fs.readFileSync(checkPath, "utf8"));
const report = JSON.parse(fs.readFileSync(runPath, "utf8"));

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function stableSnapshot(value) {
  if (value === null || typeof value !== "object") {
    return value;
  }
  if (Array.isArray(value)) {
    return value.map((item) => stableSnapshot(item));
  }
  return Object.fromEntries(
    Object.keys(value)
      .sort()
      .map((key) => [key, stableSnapshot(value[key])]),
  );
}

function stable(value) {
  return JSON.stringify(stableSnapshot(value));
}

assert(check.status === "ok", `expected check status ok, got ${check.status}`);
assert(
  String(check.summary || "").includes("scenarioReport : TaskBatch -> AgentReport"),
  "check summary should include scenarioReport",
);
assert(report.objective === "close wave1 swarm fixture", "objective changed");
assert(report.nextTaskId === "fixture", `unexpected nextTaskId ${report.nextTaskId}`);
assert(report.action === "run-focused-verifier", `unexpected action ${report.action}`);
assert(report.reason === "selected fixture because priority=7", `unexpected reason ${report.reason}`);
assert(JSON.stringify(report.readyQueue) === JSON.stringify(["fixture"]), "readyQueue changed");
assert(JSON.stringify(report.blockedQueue) === JSON.stringify(["native-primitive"]), "blockedQueue changed");
assert(
  report.summary === "fixture:Add compact agent fixture:7:run-focused-verifier",
  `unexpected summary ${report.summary}`,
);

(async () => {
  const compiled = await import(pathToFileURL(compiledPath).href);
  const compiledReport = JSON.parse(compiled.main);
  assert(typeof compiled.selectNextTask === "function", "compiled JS should export selectNextTask");
  assert(typeof compiled.scenarioReport === "function", "compiled JS should export scenarioReport");
  assert(stable(compiledReport) === stable(report), "compiled JS main should match claspc run report");
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE

printf 'agent-task-scenario: ok\n'
