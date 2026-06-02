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
      running_health='"progressing"'
      running_progressing=1
      running_silent=0
      running_unknown=0
      running_no_report=1
      running_max_age=90
      running_max_silence=3
    else
      running=0
      running_health='"none"'
      running_progressing=0
      running_silent=0
      running_unknown=0
      running_no_report=0
      running_max_age=0
      running_max_silence=0
    fi
    cat <<JSON
{"wave":"full","summary":{"laneCount":2,"runningCount":$running,"stoppedCount":$((2 - running)),"completedCount":7,"blockedCount":0,"runningProgressingCount":$running_progressing,"runningSilentCount":$running_silent,"runningUnknownCount":$running_unknown,"runningNoReportCount":$running_no_report,"runningMaxAgeSeconds":$running_max_age,"runningMaxSilenceSeconds":$running_max_silence,"runningSilenceStaleSeconds":1800,"runningHealth":$running_health},"lanes":[]}
JSON
    ;;
  preflight)
    if [[ "$count" == "1" ]]; then
      cat <<'JSON'
{"schemaVersion":1,"status":"admitted","reason":"ready-task","waveName":"full","runningLanes":0,"maxRunningLanes":1,"selectedLane":"01-foundation","selectedTask":"BOOT-001","selectedLaneText":"01-foundation","selectedTaskText":"BOOT-001","resourcePressure":{"kind":"none","shortfallMb":0,"recommendedAction":"none","externalAgentProcessCount":0,"externalAgentReservedMemoryMb":0},"launchAdjustment":{"candidateProfile":"bounded-low-memory","candidateAdmissible":false,"candidateEnv":"","candidateShortfallMb":0},"repositoryGate":{"status":"clean","reason":"clean-worktree","recommendedAction":"none"}}
JSON
    else
      cat <<'JSON'
{"schemaVersion":1,"status":"blocked","reason":"memory-pressure","waveName":"full","runningLanes":0,"maxRunningLanes":1,"selectedLane":null,"selectedTask":null,"selectedLaneText":"","selectedTaskText":"","resourcePressure":{"kind":"memory","shortfallMb":256,"recommendedAction":"wait-for-memory","externalAgentProcessCount":3,"externalAgentReservedMemoryMb":4096},"launchAdjustment":{"candidateProfile":"bounded-low-memory","candidateAdmissible":true,"candidateEnv":"CLASP_SWARM_LANE_MEMORY_MB=4096 CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=32768","candidateShortfallMb":0},"repositoryGate":{"status":"not-checked","reason":"not-requested","recommendedAction":"none"}}
JSON
      exit 75
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
  CLASP_SWARM_SUPERVISOR_REPORT_EVENT_LIMIT_JSON=2 \
  CLASP_SWARM_SUPERVISOR_COMMAND_TIMEOUT_MS_JSON=30000 \
  CLASP_SWARM_SUPERVISOR_STATUS_COMMAND_JSON="[\"$fake_tool\",\"status\"]" \
  CLASP_SWARM_SUPERVISOR_PREFLIGHT_COMMAND_JSON="[\"$fake_tool\",\"preflight\"]" \
  CLASP_SWARM_SUPERVISOR_START_COMMAND_JSON="[\"$fake_tool\",\"start\"]" \
  CLASP_SWARM_SUPERVISOR_FALLBACK_START_COMMAND_JSON="[\"$fake_tool\",\"start\"]" \
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
assert(report.reportEventLimit === 2, `reportEventLimit ${report.reportEventLimit}`);
assert(Number.isInteger(report.startedAtMs) && report.startedAtMs > 0, `startedAtMs ${report.startedAtMs}`);
assert(Number.isInteger(report.updatedAtMs) && report.updatedAtMs >= report.startedAtMs, `updatedAtMs ${report.updatedAtMs}`);
assert(report.completedIterations === 3, `completedIterations ${report.completedIterations}`);
assert(report.dryRun === false, "dryRun should be false");
assert(report.admittedStarts === 2, `admittedStarts ${report.admittedStarts}`);
assert(report.totalEventCount === 3, `totalEventCount ${report.totalEventCount}`);
assert(report.retainedEventCount === 2, `retainedEventCount ${report.retainedEventCount}`);
assert(report.lastAction === "started-fallback-lane", `lastAction ${report.lastAction}`);
assert(report.lastReason === "admitted", `lastReason ${report.lastReason}`);
assert(report.lastSelectedLane === "", `lastSelectedLane ${report.lastSelectedLane}`);
assert(report.lastSelectedTask === "", `lastSelectedTask ${report.lastSelectedTask}`);
assert(report.lastResourcePressureKind === "memory", `lastResourcePressureKind ${report.lastResourcePressureKind}`);
assert(report.lastResourcePressureRecommendedAction === "wait-for-memory", `lastResourcePressureRecommendedAction ${report.lastResourcePressureRecommendedAction}`);
assert(report.lastLaunchAdjustmentCandidateProfile === "bounded-low-memory", `lastLaunchAdjustmentCandidateProfile ${report.lastLaunchAdjustmentCandidateProfile}`);
assert(report.lastLaunchAdjustmentCandidateAdmissible === true, `lastLaunchAdjustmentCandidateAdmissible ${report.lastLaunchAdjustmentCandidateAdmissible}`);
assert(report.events.length === 2, `bounded report events ${report.events.length}`);
assert(eventLines.length === 3, `event log length ${eventLines.length}`);
assert(JSON.stringify(report.events) === JSON.stringify(eventLines.slice(-2)), "report should retain the most recent bounded event window");
assert(eventLines[0].action === "started-lane", `event0 ${eventLines[0].action}`);
assert(eventLines[0].preflightStatus === "admitted", `event0 preflight ${eventLines[0].preflightStatus}`);
assert(eventLines[0].startExitCode === 0, `event0 start ${eventLines[0].startExitCode}`);
assert(eventLines[0].selectedLane === "01-foundation", `event0 selected lane ${eventLines[0].selectedLane}`);
assert(eventLines[0].selectedTask === "BOOT-001", `event0 selected task ${eventLines[0].selectedTask}`);
assert(eventLines[0].resourcePressureKind === "none", `event0 resource ${eventLines[0].resourcePressureKind}`);
assert(eventLines[0].launchAdjustmentCandidateAdmissible === false, `event0 fallback ${eventLines[0].launchAdjustmentCandidateAdmissible}`);
assert(eventLines[0].repositoryGateStatus === "clean", `event0 repo gate ${eventLines[0].repositoryGateStatus}`);
assert(eventLines[1].action === "observed-running-progressing", `event1 ${eventLines[1].action}`);
assert(eventLines[1].reason === "running-lanes-progressing", `event1 reason ${eventLines[1].reason}`);
assert(eventLines[1].runningCount === 1, `event1 running ${eventLines[1].runningCount}`);
assert(eventLines[2].action === "started-fallback-lane", `event2 ${eventLines[2].action}`);
assert(eventLines[2].preflightReason === "memory-pressure", `event2 reason ${eventLines[2].preflightReason}`);
assert(eventLines[2].startExitCode === 0, `event2 start ${eventLines[2].startExitCode}`);
assert(eventLines[2].resourcePressureKind === "memory", `event2 resource ${eventLines[2].resourcePressureKind}`);
assert(eventLines[2].resourcePressureShortfallMb === 256, `event2 shortfall ${eventLines[2].resourcePressureShortfallMb}`);
assert(eventLines[2].resourcePressureRecommendedAction === "wait-for-memory", `event2 action ${eventLines[2].resourcePressureRecommendedAction}`);
assert(eventLines[2].launchAdjustmentCandidateProfile === "bounded-low-memory", `event2 fallback profile ${eventLines[2].launchAdjustmentCandidateProfile}`);
assert(eventLines[2].launchAdjustmentCandidateAdmissible === true, `event2 fallback ${eventLines[2].launchAdjustmentCandidateAdmissible}`);
assert(eventLines[2].launchAdjustmentCandidateEnv.includes("CLASP_SWARM_LANE_MEMORY_MB=4096"), `event2 fallback env ${eventLines[2].launchAdjustmentCandidateEnv}`);
assert(eventLines[2].repositoryGateStatus === "not-checked", `event2 repo gate ${eventLines[2].repositoryGateStatus}`);
assert(count("status") === 3, `status count ${count("status")}`);
assert(count("preflight") === 2, `preflight count ${count("preflight")}`);
assert(count("start") === 2, `start count ${count("start")}`);
EOF

launcher_state_root="$test_root/launcher-state"
launcher_jobs_root="$test_root/launcher-jobs"
launcher_tool_state="$test_root/launcher-tool-state"
launcher_output_path="$test_root/launcher-output.txt"

CLASP_TEST_SWARM_TOOL_STATE="$launcher_tool_state" \
  CLASP_SWARM_SUPERVISOR_CLASPC_BIN="$claspc_bin" \
  CLASP_SWARM_SUPERVISOR_WORKSPACE_JSON="\"$project_root\"" \
  CLASP_SWARM_SUPERVISOR_STATUS_COMMAND_JSON="[\"$fake_tool\",\"status\"]" \
  CLASP_SWARM_SUPERVISOR_PREFLIGHT_COMMAND_JSON="[\"$fake_tool\",\"preflight\"]" \
  CLASP_SWARM_SUPERVISOR_START_COMMAND_JSON="[\"$fake_tool\",\"start\"]" \
  CLASP_SWARM_SUPERVISOR_FALLBACK_START_COMMAND_JSON="[\"$fake_tool\",\"start\"]" \
  CLASP_SWARM_SUPERVISOR_MIN_AVAILABLE_MEMORY_MB=0 \
  CLASP_SWARM_SUPERVISOR_MIN_AVAILABLE_DISK_MB=0 \
  CLASP_SWARM_SUPERVISOR_MIN_DISK_HEADROOM_MB=0 \
  CLASP_MANAGED_JOB_REQUIRE_MEMORY_LIMIT=0 \
  CLASP_MANAGED_JOB_DEFAULT_MIN_AVAILABLE_MEMORY_MB=0 \
  CLASP_MANAGED_JOB_EXTERNAL_AGENT_RESERVE_MB=0 \
  CLASP_MANAGED_JOB_REQUIRE_ADMISSION_LOCK=0 \
  CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root \
  bash "$project_root/scripts/clasp-swarm-supervise.sh" \
    --state-root "$launcher_state_root" \
    --jobs-root "$launcher_jobs_root" \
    --max-iterations 2 \
    --poll-ms 100 \
    --command-timeout-ms 30000 \
    --report-event-limit 5 \
    full \
    >"$launcher_output_path"

launcher_job="$(awk -F= '$1 == "supervisor_job" { print $2 }' "$launcher_output_path")"
if [[ -z "$launcher_job" || ! -d "$launcher_job" ]]; then
  printf 'launcher did not report a valid supervisor job\n' >&2
  cat "$launcher_output_path" >&2
  exit 1
fi

for _ in $(seq 1 200); do
  launcher_status="$(sed -n '1p' "$launcher_job/status" 2>/dev/null || true)"
  case "$launcher_status" in
    completed|failed|stopped|memory-exceeded|disk-exceeded|memory-enforcer-unavailable|admission-lock-unavailable)
      break
      ;;
  esac
  sleep 0.05
done

if [[ "$(sed -n '1p' "$launcher_job/status" 2>/dev/null || true)" != "completed" ]]; then
  printf 'launcher supervisor job did not complete\n' >&2
  cat "$launcher_output_path" >&2
  cat "$launcher_job/status" >&2 || true
  cat "$launcher_job/stderr.log" >&2 || true
  exit 1
fi

node - "$launcher_output_path" "$launcher_state_root" "$launcher_job" "$launcher_tool_state" <<'EOF'
const fs = require("node:fs");

const [launcherOutputPath, launcherStateRoot, launcherJob, launcherToolState] = process.argv.slice(2);
const launcherOutput = fs.readFileSync(launcherOutputPath, "utf8");
const report = JSON.parse(fs.readFileSync(`${launcherStateRoot}/supervisor-report.json`, "utf8"));
const eventLines = fs.readFileSync(`${launcherStateRoot}/supervisor-events.jsonl`, "utf8").trimEnd().split(/\n/).map((line) => JSON.parse(line));
const jobPointer = fs.readFileSync(`${launcherStateRoot}/job`, "utf8").trim();
const command = fs.readFileSync(`${launcherJob}/command.txt`, "utf8");
const memoryMb = fs.readFileSync(`${launcherJob}/memory-mb`, "utf8").trim();
const effectiveMemoryMb = fs.readFileSync(`${launcherJob}/effective-memory-mb`, "utf8").trim();
const jobStatus = fs.readFileSync(`${launcherJob}/status`, "utf8").trim();
const exitStatus = fs.readFileSync(`${launcherJob}/exit-status`, "utf8").trim();

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function count(name) {
  return Number(fs.readFileSync(`${launcherToolState}/${name}.count`, "utf8").trim());
}

assert(launcherOutput.includes(`supervisor_job=${launcherJob}`), "launcher output should expose job path");
assert(launcherOutput.includes(`supervisor_state=${launcherStateRoot}`), "launcher output should expose state path");
assert(jobPointer === launcherJob, `state job pointer ${jobPointer}`);
assert(jobStatus === "completed", `job status ${jobStatus}`);
assert(exitStatus === "0", `job exit ${exitStatus}`);
assert(memoryMb === "4096", `job memory ${memoryMb}`);
assert(effectiveMemoryMb === "4096", `effective job memory ${effectiveMemoryMb}`);
assert(command.includes("SwarmSupervisor.clasp"), "managed command should run the Clasp supervisor");
assert(command.includes("claspc"), "managed command should use claspc run");
assert(report.supervisorStatus === "completed", `supervisor status ${report.supervisorStatus}`);
assert(report.waveName === "full", `wave ${report.waveName}`);
assert(report.profileName === "bounded-memory-pressure", `profile ${report.profileName}`);
assert(report.maxIterations === 2, `maxIterations ${report.maxIterations}`);
assert(report.pollMs === 100, `pollMs ${report.pollMs}`);
assert(report.reportEventLimit === 5, `reportEventLimit ${report.reportEventLimit}`);
assert(report.completedIterations === 2, `completedIterations ${report.completedIterations}`);
assert(report.admittedStarts === 1, `admittedStarts ${report.admittedStarts}`);
assert(eventLines.length === 2, `event lines ${eventLines.length}`);
assert(eventLines[0].action === "started-lane", `event0 ${eventLines[0].action}`);
assert(eventLines[1].action === "observed-running-progressing", `event1 ${eventLines[1].action}`);
assert(eventLines[1].reason === "running-lanes-progressing", `event1 reason ${eventLines[1].reason}`);
assert(count("status") === 2, `status count ${count("status")}`);
assert(count("preflight") === 1, `preflight count ${count("preflight")}`);
assert(count("start") === 1, `start count ${count("start")}`);
EOF

printf 'swarm-native-supervisor-ok\n'
