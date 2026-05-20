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

(
  cd "$project_root"
  timeout "$timeout_secs" "$claspc_bin" --json check examples/agent-task-scenario/Main.clasp >"$check_output"
  timeout "$timeout_secs" "$claspc_bin" run examples/agent-task-scenario/Main.clasp >"$run_output"
)

node - "$check_output" "$run_output" <<'NODE'
const fs = require("node:fs");

const [checkPath, runPath] = process.argv.slice(2);
const check = JSON.parse(fs.readFileSync(checkPath, "utf8"));
const report = JSON.parse(fs.readFileSync(runPath, "utf8"));

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
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
NODE

printf 'agent-task-scenario: ok\n'
