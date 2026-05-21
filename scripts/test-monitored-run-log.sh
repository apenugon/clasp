#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_MONITORED_RUN_LOG_TIMEOUT_SECS:-120}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_MONITORED_RUN_LOG_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-monitored-run-log.XXXXXX")"
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
demo_path="$project_root/examples/feedback-loop/MonitoredRunLogDemo.clasp"

if grep -F '"bash"' "$demo_path" >/dev/null; then
  printf 'MonitoredRunLogDemo should exercise direct executables, not shell wrappers\n' >&2
  exit 1
fi

timeout "$timeout_secs" "$claspc_bin" --json check "$demo_path" | grep -F '"status":"ok"' >/dev/null
timeout "$timeout_secs" "$claspc_bin" run "$demo_path" -- "$state_root" >"$output_path"

node - "$output_path" "$state_root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const [outputPath, stateRoot] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(outputPath, "utf8"));
const events = fs
  .readFileSync(path.join(stateRoot, "monitored-runs.jsonl"), "utf8")
  .trim()
  .split(/\n/)
  .filter(Boolean)
  .map((line) => JSON.parse(line));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function persistedRun(id) {
  return JSON.parse(fs.readFileSync(path.join(stateRoot, `${id}.run.json`), "utf8"));
}

function text(name) {
  return fs.readFileSync(path.join(stateRoot, name), "utf8");
}

assert(report.scenarioId === "ordinary-clasp-monitored-run-log", "scenario id should identify the run log demo");
assert(report.finalStatus === "completed", `unexpected final status ${report.finalStatus}`);
assert(report.completed === true, "scenario should complete");
assert(report.runCount === 3, "scenario should run pass, fail, and timeout commands");
assert(report.passStatus === "completed-pass", "pass command should pass");
assert(report.failStatus === "completed-fail", "nonzero command should be classified as completed-fail");
assert(report.timeoutStatus === "timeout", "timeout command should be classified as timeout");

const pass = report.passRun;
const fail = report.failRun;
const timeout = report.timeoutRun;

assert(pass.exitCode === 0 && pass.stdout === "pass-out" && pass.stderr === "pass-err", "pass output should be captured");
assert(fail.exitCode === 5 && fail.stdout === "fail-out" && fail.stderr === "fail-err", "fail output should be captured");
assert(timeout.exitCode === 124 && timeout.timedOut === true && timeout.error === "timeout", "timeout shape should be durable");
assert(timeout.stdout === "timeout-start", "timeout stdout before cancellation should be captured");
assert(Array.isArray(pass.command) && pass.command[0] === "node", "pass command should be durable");
assert(Array.isArray(fail.command) && fail.command[0] === "node", "fail command should be durable");
assert(Array.isArray(timeout.command) && timeout.command[0] === "node", "timeout command should be durable");

for (const run of [pass, fail, timeout]) {
  const persisted = persistedRun(run.runId);
  assert(JSON.stringify(persisted) === JSON.stringify(run), `${run.runId} persisted status should match output`);
  assert(run.statusPath === path.join(stateRoot, `${run.runId}.run.json`), `${run.runId} status path should be explicit`);
  assert(run.eventLogPath === path.join(stateRoot, "monitored-runs.jsonl"), `${run.runId} event log path should be explicit`);
  assert(run.startedAtMs > 0 && run.endedAtMs >= run.startedAtMs, `${run.runId} should capture timing`);
  assert(run.durationMs >= 0, `${run.runId} should capture duration`);
}

assert(text("pass.stdout.log") === "pass-out", "pass stdout artifact should persist");
assert(text("fail.stderr.log") === "fail-err", "fail stderr artifact should persist");
assert(text("timeout.stdout.log") === "timeout-start", "timeout stdout artifact should persist");

assert(events.length === 6, `expected start/completion events for each run, got ${events.length}`);
for (const id of ["pass", "fail", "timeout"]) {
  const startIndex = events.findIndex((event) => event.runId === id && event.kind === "run-started");
  const finishIndex = events.findIndex((event) => event.runId === id && event.kind === "run-completed");
  assert(startIndex >= 0, `${id} start event should persist`);
  assert(finishIndex > startIndex, `${id} completion event should follow start event`);
  assert(events[startIndex].atMs <= events[finishIndex].atMs, `${id} event timestamps should be ordered`);
}
assert(events.some((event) => event.runId === "pass" && event.kind === "run-completed" && event.status === "completed-pass"), "pass completion event should persist");
assert(events.some((event) => event.runId === "fail" && event.kind === "run-completed" && event.status === "completed-fail"), "fail completion event should persist");
assert(events.some((event) => event.runId === "timeout" && event.kind === "run-completed" && event.status === "timeout"), "timeout completion event should persist");
NODE

printf 'monitored-run-log-ok\n'
