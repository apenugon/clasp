#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_MONITORED_WORKFLOW_TIMEOUT_SECS:-120}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_MONITORED_WORKFLOW_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-monitored-workflow.XXXXXX")"
output_path="$test_root/output.json"
state_root="$test_root/state"
test_xdg_cache_home="${CLASP_TEST_SHARED_XDG_CACHE_HOME:-$tmp_root/clasp-test-xdg-cache}"
if [[ "${CLASP_TEST_ISOLATED_XDG_CACHE:-0}" == "1" ]]; then
  test_xdg_cache_home="$test_root/xdg-cache"
fi
mkdir -p "$test_xdg_cache_home"
export XDG_CACHE_HOME="$test_xdg_cache_home"

cleanup() {
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root" >&2
  else
    rm -rf "$test_root" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

claspc_bin="$(
  env -u CLASP_CLASPC -u CLASPC_BIN CLASP_PROJECT_ROOT="$project_root" \
    "$project_root/scripts/resolve-claspc.sh"
)"
demo_path="$project_root/examples/feedback-loop/MonitoredWorkflowDemo.clasp"

if grep -F '"bash"' "$demo_path" >/dev/null; then
  printf 'MonitoredWorkflowDemo should exercise direct executables, not shell wrappers\n' >&2
  exit 1
fi

timeout "$timeout_secs" "$claspc_bin" --json check "$demo_path" | grep -F '"status":"ok"' >/dev/null
timeout "$timeout_secs" "$claspc_bin" run "$demo_path" -- "$state_root" >"$output_path"

node - "$output_path" "$state_root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const outputPath = process.argv[2];
const stateRoot = process.argv[3];
const report = JSON.parse(fs.readFileSync(outputPath, "utf8"));
const persisted = JSON.parse(fs.readFileSync(path.join(stateRoot, "workflow-status.json"), "utf8"));
const events = fs
  .readFileSync(path.join(stateRoot, "workflow-events.jsonl"), "utf8")
  .trim()
  .split(/\n/)
  .filter(Boolean)
  .map((line) => JSON.parse(line));

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function step(id) {
  const found = report.steps.find((entry) => entry.stepId === id);
  assert(found, `missing step ${id}`);
  return found;
}

function readText(name) {
  return fs.readFileSync(path.join(stateRoot, name), "utf8");
}

assert(report.workflowId === "ordinary-clasp-monitored-workflow", "workflow id should identify the scenario");
assert(report.finalStatus === "failed-handled", `unexpected final status ${report.finalStatus}`);
assert(report.completed === true, "workflow should be complete");
assert(report.failed === true, "workflow should record the failing verifier step");
assert(report.failureHandled === true, "workflow should mark the failure handler as successful");
assert(report.failedStepId === "verify", `unexpected failed step ${report.failedStepId}`);
assert(report.stepCount === 3, "workflow should run three monitored steps");
assert(report.passCount === 2, "plan and failure handler should pass");
assert(report.failCount === 1, "verifier should be the only failed step");
assert(JSON.stringify(report) === JSON.stringify(persisted), "final status should be durably persisted");

const plan = step("plan");
const verify = step("verify");
const handler = step("failure-handler");

assert(plan.ok === true && plan.status === "completed-pass" && plan.exitCode === 0, "plan step should pass");
assert(verify.ok === false && verify.status === "completed-fail" && verify.exitCode === 17, "verify step should fail under supervision");
assert(handler.ok === true && handler.failureHandled === true, "failure handler should pass and mark handling");
assert(plan.stdout === "plan-ok", "plan stdout should be captured");
assert(verify.stdout === "verify-output", "verify stdout should be captured");
assert(verify.stderr === "verifier failed intentionally", "verify stderr should be captured");
assert(handler.stdout === "failure-recorded", "handler stdout should be captured");
assert(Array.isArray(plan.command) && plan.command[0] === "node", "plan command should be durable");
assert(Array.isArray(verify.command) && verify.command[0] === "node", "verify command should be durable");
assert(plan.startedAtMs > 0 && plan.endedAtMs >= plan.startedAtMs, "plan timing should be captured");
assert(verify.startedAtMs > 0 && verify.endedAtMs >= verify.startedAtMs, "verify timing should be captured");
assert(handler.durationMs >= 0, "handler duration should be captured");
assert(plan.error === "", "passing plan should not set an error");

assert(readText("plan.stdout.log") === "plan-ok", "plan stdout artifact should persist");
assert(readText("verify.stdout.log") === "verify-output", "verify stdout artifact should persist");
assert(readText("verify.stderr.log") === "verifier failed intentionally", "verify stderr artifact should persist");
assert(readText("failure-handler.stdout.log") === "failure-recorded", "handler stdout artifact should persist");

const verifyHeartbeat = JSON.parse(readText("verify.heartbeat.json"));
assert(verifyHeartbeat.completed === true, "verify heartbeat should be final");
assert(verifyHeartbeat.exitCode === 17, "verify heartbeat should preserve exit status");
assert(verifyHeartbeat.status === "completed-fail", "verify heartbeat should project status");
assert(Array.isArray(verifyHeartbeat.command) && verifyHeartbeat.command[0] === "node", "verify heartbeat should preserve command");
assert(verifyHeartbeat.startedAtMs > 0 && verifyHeartbeat.endedAtMs >= verifyHeartbeat.startedAtMs, "verify heartbeat should preserve timing");

for (const id of ["plan", "verify", "failure-handler"]) {
  const status = JSON.parse(readText(`${id}.status.json`));
  assert(status.stepId === id, `${id} status artifact should be readable`);
  assert(Array.isArray(status.command) && status.command.length >= 3, `${id} status should persist command`);
  assert(status.startedAtMs > 0 && status.endedAtMs >= status.startedAtMs, `${id} status should persist timing`);
}

assert(events.filter((event) => event.kind === "step-started").length === 3, "each step should log start");
assert(events.filter((event) => event.kind === "step-completed").length === 3, "each step should log completion");
assert(events.some((event) => event.kind === "failure-detected" && event.stepId === "verify"), "failure detection should be logged");
assert(events.some((event) => event.kind === "workflow-completed" && event.status === "failed-handled"), "final event should be logged");
NODE

printf 'monitored-workflow-ok\n'
