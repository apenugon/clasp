#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-swarm-native-supervisor.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}

trap cleanup EXIT

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN CLASP_PROJECT_ROOT="$project_root" "$project_root/scripts/resolve-claspc.sh")"
state_root="$test_root/state"
fake_tool="$test_root/fake-swarm-control"
tool_state="$test_root/tool-state"
output_path="$test_root/output.json"
status_output_path="$test_root/status-output.json"

cat >"$fake_tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
state_dir="${CLASP_TEST_SWARM_TOOL_STATE:?}"
mkdir -p "$state_dir"

count_file="$state_dir/${mode}.count"
count=0
if [[ -f "$count_file" ]]; then
  count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"

case "$mode" in
  status)
    if [[ "$count" == "2" ]]; then
      running=1
    else
      running=0
    fi
    cat <<JSON
{"wave":"full","summary":{"laneCount":2,"runningCount":$running,"stoppedCount":$((2 - running)),"completedCount":7,"blockedCount":0},"lanes":[]}
JSON
    ;;
  preflight)
    if [[ "$count" == "1" ]]; then
      cat <<'JSON'
{"schemaVersion":1,"status":"admitted","reason":"ready-task","waveName":"full","runningLanes":0,"maxRunningLanes":1,"selectedLane":"01-foundation","selectedTask":"BOOT-001","selectedLaneText":"01-foundation","selectedTaskText":"BOOT-001","resourcePressure":{"kind":"none","shortfallMb":0,"recommendedAction":"none","externalAgentProcessCount":0,"externalAgentReservedMemoryMb":0},"repositoryGate":{"status":"clean","reason":"clean-worktree","recommendedAction":"none"}}
JSON
    else
      cat <<'JSON'
{"schemaVersion":1,"status":"blocked","reason":"memory-pressure","waveName":"full","runningLanes":0,"maxRunningLanes":1,"selectedLane":null,"selectedTask":null,"selectedLaneText":"","selectedTaskText":"","resourcePressure":{"kind":"memory","shortfallMb":256,"recommendedAction":"wait-for-memory","externalAgentProcessCount":3,"externalAgentReservedMemoryMb":4096},"repositoryGate":{"status":"not-checked","reason":"not-requested","recommendedAction":"none"}}
JSON
    fi
    ;;
  start)
    printf 'started fake lane\n'
    ;;
  *)
    printf 'unknown mode: %s\n' "$mode" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$fake_tool"

"$claspc_bin" --json check "$project_root/examples/swarm-native/SwarmSupervisor.clasp" |
  grep -F '"status":"ok"' >/dev/null

CLASP_TEST_SWARM_TOOL_STATE="$tool_state" \
  CLASP_SWARM_SUPERVISOR_WORKSPACE_JSON="\"$project_root\"" \
  CLASP_SWARM_SUPERVISOR_MAX_ITERATIONS_JSON=3 \
  CLASP_SWARM_SUPERVISOR_POLL_MS_JSON=0 \
  CLASP_SWARM_SUPERVISOR_COMMAND_TIMEOUT_MS_JSON=30000 \
  CLASP_SWARM_SUPERVISOR_STATUS_COMMAND_JSON="[\"$fake_tool\",\"status\"]" \
  CLASP_SWARM_SUPERVISOR_PREFLIGHT_COMMAND_JSON="[\"$fake_tool\",\"preflight\"]" \
  CLASP_SWARM_SUPERVISOR_START_COMMAND_JSON="[\"$fake_tool\",\"start\"]" \
  "$claspc_bin" run "$project_root/examples/swarm-native/SwarmSupervisor.clasp" -- "$state_root" \
  >"$output_path"

CLASP_SWARM_SUPERVISOR_MODE_JSON='"status"' \
  "$claspc_bin" run "$project_root/examples/swarm-native/SwarmSupervisor.clasp" -- "$state_root" \
  >"$status_output_path"

node - "$output_path" "$status_output_path" "$state_root/supervisor-report.json" "$state_root/supervisor-events.jsonl" "$tool_state" <<'EOF'
const fs = require("node:fs");

const [outputPath, statusOutputPath, reportPath, eventLogPath, toolState] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(outputPath, "utf8"));
const statusReport = JSON.parse(fs.readFileSync(statusOutputPath, "utf8"));
const persisted = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const eventLines = fs.readFileSync(eventLogPath, "utf8").trimEnd().split(/\n/).map((line) => JSON.parse(line));

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function count(name) {
  return Number(fs.readFileSync(`${toolState}/${name}.count`, "utf8").trim());
}

assert(JSON.stringify(report) === JSON.stringify(persisted), "persisted supervisor report should match stdout");
assert(JSON.stringify(statusReport) === JSON.stringify(persisted), "status mode should return the persisted supervisor report");
assert(report.supervisorStatus === "completed", `status ${report.supervisorStatus}`);
assert(report.waveName === "full", `wave ${report.waveName}`);
assert(report.profileName === "bounded-memory-pressure", `profile ${report.profileName}`);
assert(report.maxIterations === 3, `maxIterations ${report.maxIterations}`);
assert(report.pollMs === 0, `pollMs ${report.pollMs}`);
assert(report.dryRun === false, "dryRun should be false");
assert(report.admittedStarts === 1, `admittedStarts ${report.admittedStarts}`);
assert(report.lastAction === "preflight-blocked", `lastAction ${report.lastAction}`);
assert(report.lastReason === "memory-pressure", `lastReason ${report.lastReason}`);
assert(report.lastSelectedLane === "", `lastSelectedLane ${report.lastSelectedLane}`);
assert(report.lastSelectedTask === "", `lastSelectedTask ${report.lastSelectedTask}`);
assert(report.lastResourcePressureKind === "memory", `lastResourcePressureKind ${report.lastResourcePressureKind}`);
assert(report.lastResourcePressureRecommendedAction === "wait-for-memory", `lastResourcePressureRecommendedAction ${report.lastResourcePressureRecommendedAction}`);
assert(report.events.length === 3, `events ${report.events.length}`);
assert(report.events[0].action === "started-lane", `event0 ${report.events[0].action}`);
assert(report.events[0].preflightStatus === "admitted", `event0 preflight ${report.events[0].preflightStatus}`);
assert(report.events[0].startExitCode === 0, `event0 start ${report.events[0].startExitCode}`);
assert(report.events[0].selectedLane === "01-foundation", `event0 selected lane ${report.events[0].selectedLane}`);
assert(report.events[0].selectedTask === "BOOT-001", `event0 selected task ${report.events[0].selectedTask}`);
assert(report.events[0].resourcePressureKind === "none", `event0 resource ${report.events[0].resourcePressureKind}`);
assert(report.events[0].repositoryGateStatus === "clean", `event0 repo gate ${report.events[0].repositoryGateStatus}`);
assert(report.events[1].action === "observed-running", `event1 ${report.events[1].action}`);
assert(report.events[1].runningCount === 1, `event1 running ${report.events[1].runningCount}`);
assert(report.events[2].action === "preflight-blocked", `event2 ${report.events[2].action}`);
assert(report.events[2].preflightReason === "memory-pressure", `event2 reason ${report.events[2].preflightReason}`);
assert(report.events[2].resourcePressureKind === "memory", `event2 resource ${report.events[2].resourcePressureKind}`);
assert(report.events[2].resourcePressureShortfallMb === 256, `event2 shortfall ${report.events[2].resourcePressureShortfallMb}`);
assert(report.events[2].resourcePressureRecommendedAction === "wait-for-memory", `event2 action ${report.events[2].resourcePressureRecommendedAction}`);
assert(report.events[2].repositoryGateStatus === "not-checked", `event2 repo gate ${report.events[2].repositoryGateStatus}`);
assert(eventLines.length === 3, `event log length ${eventLines.length}`);
assert(JSON.stringify(eventLines) === JSON.stringify(report.events), "event log should persist each iteration event in order");
assert(count("status") === 3, `status count ${count("status")}`);
assert(count("preflight") === 2, `preflight count ${count("preflight")}`);
assert(count("start") === 1, `start count ${count("start")}`);
EOF

printf 'swarm-native-supervisor-ok\n'
