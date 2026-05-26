#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-swarm-memory.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN -u RUSTC "$project_root/scripts/resolve-claspc.sh")"
cli_state_root="$test_root/cli-state"
program_state_root="$test_root/program-state"

"$claspc_bin" --json swarm objective create "$cli_state_root" memory-cli \
  --detail "Persist memory through the native CLI." \
  --max-tasks 1 \
  --max-runs 4 \
  >"$test_root/cli-objective.json"

"$claspc_bin" --json swarm task create "$cli_state_root" memory-cli memory-task \
  --detail "Record and query a native memory item." \
  --max-runs 4 \
  >"$test_root/cli-task.json"

"$claspc_bin" --json swarm memory put "$cli_state_root" lesson cli-memory \
  --objective memory-cli \
  --task memory-task \
  --actor cli-agent \
  >"$test_root/cli-memory-put.json"

"$claspc_bin" --json swarm memory query "$cli_state_root" \
  --objective memory-cli \
  --task memory-task \
  --key lesson \
  --limit 10 \
  >"$test_root/cli-memory-query.json"

"$claspc_bin" --json swarm memory search "$cli_state_root" "cli memory" \
  --objective memory-cli \
  --limit 10 \
  >"$test_root/cli-memory-search.json"

node - "$test_root/cli-memory-put.json" "$test_root/cli-memory-query.json" "$test_root/cli-memory-search.json" <<'EOF'
const fs = require("node:fs");

const put = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const query = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const search = JSON.parse(fs.readFileSync(process.argv[4], "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(put.objectiveId === "memory-cli", `put objective ${put.objectiveId}`);
assert(put.taskId === "memory-task", `put task ${put.taskId}`);
assert(put.actor === "cli-agent", `put actor ${put.actor}`);
assert(put.key === "lesson", `put key ${put.key}`);
assert(put.value === "cli-memory", `put value ${put.value}`);
assert(Array.isArray(query), "query is not an array");
assert(query.length === 1, `query length ${query.length}`);
assert(query[0].memoryId === put.memoryId, "query did not return inserted record");
assert(query[0].value === "cli-memory", `query value ${query[0].value}`);
assert(Array.isArray(search), "search is not an array");
assert(search.length >= 1, `search length ${search.length}`);
assert(search[0].memory.memoryId === put.memoryId, "search did not rank inserted record first");
assert(search[0].score > 0, `search score ${search[0].score}`);
assert(search[0].matchedText === "cli-memory", `search matched text ${search[0].matchedText}`);
EOF

env RUSTC=/definitely-missing-rustc \
  timeout 120 \
  "$claspc_bin" run "$project_root/examples/swarm-native/MemoryHarness.clasp" -- "$program_state_root" \
  >"$test_root/memory-harness.json"

if grep -F 'error:' "$test_root/memory-harness.json" >/dev/null; then
  cat "$test_root/memory-harness.json" >&2
  exit 1
fi

node - "$test_root/memory-harness.json" <<'EOF'
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

assert(report.objectiveMemory.objectiveId === "memory-objective", "objective memory objective id");
assert(report.objectiveMemory.taskId === "", "objective memory should not have a task id");
assert(report.objectiveMemory.value === "prefer-durable-objective-memory", "objective memory value");
assert(report.taskMemory.taskId === "memory-task", "task memory task id");
assert(report.taskMemory.actor === "memory-agent", "task memory actor");
assert(report.taskMemory.value === "prefer-durable-task-memory", "task memory value");
sameList(report.objectiveValues, ["prefer-durable-objective-memory"], "objective values");
sameList(report.taskValues, ["prefer-durable-task-memory"], "task values");
assert(report.allValues.includes("prefer-durable-objective-memory"), "all values missing objective memory");
assert(report.allValues.includes("prefer-durable-task-memory"), "all values missing task memory");
sameList(report.searchValues, ["prefer-durable-task-memory", "prefer-durable-objective-memory"], "search values");
assert(report.searchScores[0] > report.searchScores[1], `search scores ${JSON.stringify(report.searchScores)}`);
sameList(report.mailboxValues, ["prefer-durable-task-memory"], "mailbox memory values");
assert(report.mailboxMemoryCount === 1, `mailbox memory count ${report.mailboxMemoryCount}`);
EOF
