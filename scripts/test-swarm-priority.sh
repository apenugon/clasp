#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-swarm-priority.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

expect_command_failure_contains() {
  local expected="$1"
  shift
  local output
  local status

  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  if [[ "$status" == "0" ]]; then
    printf 'expected command to fail: %s\n' "$*" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if ! printf '%s\n' "$output" | grep -F "$expected" >/dev/null; then
    printf 'expected failure output to contain: %s\n' "$expected" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN -u RUSTC "$project_root/scripts/resolve-claspc.sh")"
cli_state_root="$test_root/cli-state"
program_state_root="$test_root/program-state"

"$claspc_bin" --json swarm objective create "$cli_state_root" priority-cli \
  --detail "Choose work by task priority." \
  --max-tasks 4 \
  --max-runs 8 \
  >"$test_root/cli-objective.json"

"$claspc_bin" --json swarm task create "$cli_state_root" priority-cli early \
  --detail "Earlier lower-priority task." \
  --max-runs 4 \
  --priority 1 \
  >"$test_root/cli-early.json"

"$claspc_bin" --json swarm task create "$cli_state_root" priority-cli late \
  --detail "Later higher-priority task." \
  --max-runs 4 \
  --priority 10 \
  >"$test_root/cli-late.json"

"$claspc_bin" --json swarm ready "$cli_state_root" priority-cli >"$test_root/cli-ready-before.json"
"$claspc_bin" --json swarm manager next "$cli_state_root" priority-cli >"$test_root/cli-manager-before.json"
"$claspc_bin" --json swarm task reprioritize "$cli_state_root" early 20 >"$test_root/cli-reprioritize.json"
"$claspc_bin" --json swarm ready "$cli_state_root" priority-cli >"$test_root/cli-ready-after.json"
"$claspc_bin" --json swarm manager next "$cli_state_root" priority-cli >"$test_root/cli-manager-after.json"
"$claspc_bin" --json swarm status "$cli_state_root" early >"$test_root/cli-status.json"
"$claspc_bin" --json swarm tail "$cli_state_root" early --limit 8 >"$test_root/cli-tail.json"

expect_command_failure_contains 'actor `intruder` is not a swarm manager' \
  env CLASP_SWARM_ACTOR=intruder \
  "$claspc_bin" --json swarm task reprioritize "$cli_state_root" early 30

node - \
  "$test_root/cli-early.json" \
  "$test_root/cli-late.json" \
  "$test_root/cli-ready-before.json" \
  "$test_root/cli-manager-before.json" \
  "$test_root/cli-reprioritize.json" \
  "$test_root/cli-ready-after.json" \
  "$test_root/cli-manager-after.json" \
  "$test_root/cli-status.json" \
  "$test_root/cli-tail.json" <<'EOF'
const fs = require("node:fs");

const [
  earlyPath,
  latePath,
  readyBeforePath,
  managerBeforePath,
  reprioritizePath,
  readyAfterPath,
  managerAfterPath,
  statusPath,
  tailPath,
] = process.argv.slice(2);

const read = (file) => JSON.parse(fs.readFileSync(file, "utf8"));
const early = read(earlyPath);
const late = read(latePath);
const readyBefore = read(readyBeforePath);
const managerBefore = read(managerBeforePath);
const reprioritized = read(reprioritizePath);
const readyAfter = read(readyAfterPath);
const managerAfter = read(managerAfterPath);
const status = read(statusPath);
const tail = read(tailPath);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function taskIds(tasks) {
  assert(Array.isArray(tasks), "tasks is not an array");
  return tasks.map((task) => task.taskId);
}

assert(early.priority === 1, `early priority ${early.priority}`);
assert(late.priority === 10, `late priority ${late.priority}`);
assert(JSON.stringify(taskIds(readyBefore)) === JSON.stringify(["late", "early"]), `ready before ${JSON.stringify(taskIds(readyBefore))}`);
assert(managerBefore.taskId === "late", `manager before task ${managerBefore.taskId}`);
assert(managerBefore.taskPriority === 10, `manager before priority ${managerBefore.taskPriority}`);
assert(reprioritized.priority === 20, `reprioritized priority ${reprioritized.priority}`);
assert(JSON.stringify(taskIds(readyAfter)) === JSON.stringify(["early", "late"]), `ready after ${JSON.stringify(taskIds(readyAfter))}`);
assert(managerAfter.taskId === "early", `manager after task ${managerAfter.taskId}`);
assert(managerAfter.taskPriority === 20, `manager after priority ${managerAfter.taskPriority}`);
assert(status.priority === 20, `status priority ${status.priority}`);
assert(Array.isArray(tail), "tail is not an array");
const event = tail.find((entry) => entry.kind === "task_reprioritized");
assert(event, `reprioritize event missing from tail ${JSON.stringify(tail)}`);
assert(event.payload?.previousPriority === 1, `previous priority ${JSON.stringify(event.payload)}`);
assert(event.payload?.priority === 20, `event priority ${JSON.stringify(event.payload)}`);
EOF

env RUSTC=/definitely-missing-rustc \
  timeout 120 \
  "$claspc_bin" run "$project_root/examples/swarm-native/PriorityHarness.clasp" -- "$program_state_root" \
  >"$test_root/priority-harness.json"

if grep -F 'error:' "$test_root/priority-harness.json" >/dev/null; then
  cat "$test_root/priority-harness.json" >&2
  exit 1
fi

node - "$test_root/priority-harness.json" <<'EOF'
const fs = require("node:fs");

const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function sameList(actual, expected, label) {
  assert(Array.isArray(actual), `${label} is not an array`);
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${label} expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
  );
}

assert(report.firstPriority === 1, `first priority ${report.firstPriority}`);
assert(report.secondPriority === 9, `second priority ${report.secondPriority}`);
sameList(report.readyBefore, ["second", "first"], "ready before");
assert(report.managerBeforeTask === "second", `manager before ${report.managerBeforeTask}`);
assert(report.managerBeforePriority === 9, `manager before priority ${report.managerBeforePriority}`);
assert(report.reprioritizedPriority === 12, `reprioritized priority ${report.reprioritizedPriority}`);
sameList(report.readyAfter, ["first", "second"], "ready after");
assert(report.managerAfterTask === "first", `manager after ${report.managerAfterTask}`);
assert(report.managerAfterPriority === 12, `manager after priority ${report.managerAfterPriority}`);
assert(report.statusPriority === 12, `status priority ${report.statusPriority}`);
assert(report.historyKinds.includes("task_reprioritized"), `history kinds ${JSON.stringify(report.historyKinds)}`);
EOF

printf 'swarm-priority-ok\n'
