#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-swarm-spawn-policy.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT
export CLASP_NATIVE_JOBS_MAX="${CLASP_NATIVE_JOBS_MAX:-1}"
export CLASP_NATIVE_BUNDLE_JOBS="${CLASP_NATIVE_BUNDLE_JOBS:-1}"
export CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX="${CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX:-1}"
export CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS="${CLASP_NATIVE_IMAGE_MODULE_DECL_FRESH_PROCESS:-0}"
export CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE="${CLASP_SWARM_SPAWN_POLICY_MODULE_DECL_CHUNK_SIZE:-4}"
spawn_policy_timeout_secs="${CLASP_SWARM_SPAWN_POLICY_TIMEOUT_SECS:-240}"

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

"$claspc_bin" --json swarm objective create "$cli_state_root" spawn-cli \
  --detail "Bound task child spawning." \
  --max-tasks 5 \
  --max-runs 8 \
  >"$test_root/cli-objective.json"

"$claspc_bin" --json swarm task create "$cli_state_root" spawn-cli root \
  --detail "Root spawning task." \
  --max-runs 2 \
  --max-spawn-depth 1 \
  --max-child-tasks 1 \
  >"$test_root/cli-root.json"

"$claspc_bin" --json swarm task create "$cli_state_root" spawn-cli child \
  --detail "Allowed child task." \
  --max-runs 2 \
  --parent-task root \
  >"$test_root/cli-child.json"

expect_command_failure_contains 'parent swarm task `child` exhausted its spawn depth budget 1' \
  "$claspc_bin" --json swarm task create "$cli_state_root" spawn-cli grandchild \
    --detail "Blocked grandchild task." \
    --max-runs 2 \
    --parent-task child

expect_command_failure_contains 'parent swarm task `root` exhausted its child task budget 1' \
  "$claspc_bin" --json swarm task create "$cli_state_root" spawn-cli sibling \
    --detail "Blocked sibling task." \
    --max-runs 2 \
    --parent-task root

"$claspc_bin" --json swarm status "$cli_state_root" root >"$test_root/cli-root-status.json"
"$claspc_bin" --json swarm status "$cli_state_root" child >"$test_root/cli-child-status.json"
"$claspc_bin" --json swarm tail "$cli_state_root" child --limit 8 >"$test_root/cli-child-tail.json"

node - \
  "$test_root/cli-root.json" \
  "$test_root/cli-child.json" \
  "$test_root/cli-root-status.json" \
  "$test_root/cli-child-status.json" \
  "$test_root/cli-child-tail.json" <<'EOF'
const fs = require("node:fs");

const [rootPath, childPath, rootStatusPath, childStatusPath, childTailPath] = process.argv.slice(2);
const read = (file) => JSON.parse(fs.readFileSync(file, "utf8"));
const root = read(rootPath);
const child = read(childPath);
const rootStatus = read(rootStatusPath);
const childStatus = read(childStatusPath);
const childTail = read(childTailPath);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(root.parentTaskId === "", `root parent ${root.parentTaskId}`);
assert(root.spawnDepth === 0, `root depth ${root.spawnDepth}`);
assert(root.maxSpawnDepth === 1, `root max depth ${root.maxSpawnDepth}`);
assert(root.maxChildTasks === 1, `root max child tasks ${root.maxChildTasks}`);
assert(Array.isArray(root.childTaskIds), `root child ids ${JSON.stringify(root.childTaskIds)}`);
assert(root.childTaskIds.length === 0, `root create child ids ${JSON.stringify(root.childTaskIds)}`);
assert(root.childTaskCount === 0, `root create child count ${root.childTaskCount}`);
assert(root.remainingChildTaskBudget === 1, `root create remaining budget ${root.remainingChildTaskBudget}`);
assert(rootStatus.childTaskIds.includes("child"), `root status child ids ${JSON.stringify(rootStatus.childTaskIds)}`);
assert(rootStatus.childTaskCount === 1, `root status child count ${rootStatus.childTaskCount}`);
assert(rootStatus.remainingChildTaskBudget === 0, `root status remaining budget ${rootStatus.remainingChildTaskBudget}`);
assert(child.parentTaskId === "root", `child parent ${child.parentTaskId}`);
assert(child.spawnDepth === 1, `child depth ${child.spawnDepth}`);
assert(child.maxSpawnDepth === 1, `child max depth ${child.maxSpawnDepth}`);
assert(child.maxChildTasks === 0, `child max child tasks ${child.maxChildTasks}`);
assert(Array.isArray(child.childTaskIds), `child ids ${JSON.stringify(child.childTaskIds)}`);
assert(child.childTaskCount === 0, `child child count ${child.childTaskCount}`);
assert(child.remainingChildTaskBudget === 0, `child remaining budget ${child.remainingChildTaskBudget}`);
assert(childStatus.parentTaskId === "root", `child status parent ${childStatus.parentTaskId}`);
assert(childStatus.childTaskCount === 0, `child status child count ${childStatus.childTaskCount}`);
assert(childStatus.remainingChildTaskBudget === 0, `child status remaining budget ${childStatus.remainingChildTaskBudget}`);
assert(Array.isArray(childTail), "child tail is not an array");
const created = childTail.find((entry) => entry.kind === "task_created");
assert(created, `child task_created event missing ${JSON.stringify(childTail)}`);
assert(created.payload?.parentTaskId === "root", `event parent ${JSON.stringify(created.payload)}`);
assert(created.payload?.spawnDepth === 1, `event depth ${JSON.stringify(created.payload)}`);
assert(created.payload?.maxSpawnDepth === 1, `event max depth ${JSON.stringify(created.payload)}`);
assert(created.payload?.maxChildTasks === 0, `event max child tasks ${JSON.stringify(created.payload)}`);
EOF

env RUSTC=/definitely-missing-rustc \
  timeout "$spawn_policy_timeout_secs" \
  "$claspc_bin" run "$project_root/examples/swarm-native/SpawnPolicyHarness.clasp" -- "$program_state_root" \
  >"$test_root/spawn-policy-harness.json"

if grep -F 'error:' "$test_root/spawn-policy-harness.json" >/dev/null; then
  cat "$test_root/spawn-policy-harness.json" >&2
  exit 1
fi

node - "$test_root/spawn-policy-harness.json" <<'EOF'
const fs = require("node:fs");

const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(report.rootTaskId === "root", `root id ${report.rootTaskId}`);
assert(report.rootParentTaskId === "", `root parent ${report.rootParentTaskId}`);
assert(report.rootSpawnDepth === 0, `root depth ${report.rootSpawnDepth}`);
assert(report.rootMaxSpawnDepth === 1, `root max depth ${report.rootMaxSpawnDepth}`);
assert(report.rootMaxChildTasks === 1, `root max child tasks ${report.rootMaxChildTasks}`);
assert(report.rootStatusChildTaskIds.includes("child"), `root child ids ${JSON.stringify(report.rootStatusChildTaskIds)}`);
assert(report.rootStatusChildTaskCount === 1, `root child count ${report.rootStatusChildTaskCount}`);
assert(
  report.rootStatusRemainingChildTaskBudget === 0,
  `root remaining child budget ${report.rootStatusRemainingChildTaskBudget}`,
);
assert(report.childTaskId === "child", `child id ${report.childTaskId}`);
assert(report.childParentTaskId === "root", `child parent ${report.childParentTaskId}`);
assert(report.childSpawnDepth === 1, `child depth ${report.childSpawnDepth}`);
assert(report.childMaxSpawnDepth === 1, `child max depth ${report.childMaxSpawnDepth}`);
assert(report.childMaxChildTasks === 0, `child max child tasks ${report.childMaxChildTasks}`);
assert(report.childStatusParentTaskId === "root", `child status parent ${report.childStatusParentTaskId}`);
assert(Array.isArray(report.childStatusChildTaskIds), `child status child ids ${JSON.stringify(report.childStatusChildTaskIds)}`);
assert(report.childStatusChildTaskCount === 0, `child status child count ${report.childStatusChildTaskCount}`);
assert(
  report.childStatusRemainingChildTaskBudget === 0,
  `child remaining child budget ${report.childStatusRemainingChildTaskBudget}`,
);
assert(report.blockedGrandchild === true, `blocked grandchild ${report.blockedGrandchild}`);
assert(
  report.blockedGrandchildMessage.includes("parent swarm task `child` exhausted its spawn depth budget 1"),
  `blocked grandchild message ${report.blockedGrandchildMessage}`,
);
assert(report.blockedSibling === true, `blocked sibling ${report.blockedSibling}`);
assert(
  report.blockedSiblingMessage.includes("parent swarm task `root` exhausted its child task budget 1"),
  `blocked sibling message ${report.blockedSiblingMessage}`,
);
EOF

printf 'swarm-spawn-policy-ok\n'
