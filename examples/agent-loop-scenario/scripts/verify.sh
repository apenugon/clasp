#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_AGENT_LOOP_SCENARIO_TIMEOUT_SECS:-120}"
test_root=""

fail() {
  printf 'agent-loop-scenario verify: %s\n' "$*" >&2
  exit 1
}

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  fail "CLASP_AGENT_LOOP_SCENARIO_TIMEOUT_SECS must be a positive integer"
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/agent-loop-scenario.XXXXXX")"
workspace_root="$test_root/workspace"
fake_codex="$test_root/codex"
run_output="$test_root/run.json"
handoff_output="$test_root/handoff-run.json"
handoff_workspace="$test_root/handoff-workspace"

cleanup() {
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root" >&2
  else
    rm -rf "${test_root:-}" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

mkdir -p "$workspace_root/src" "$workspace_root/artifacts"
mkdir -p "$handoff_workspace"
printf 'alpha task input\n' > "$workspace_root/src/input.txt"

cat > "$fake_codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "exec" ]]; then
  printf 'expected codex exec, got: %s\n' "$*" >&2
  exit 64
fi

output_path=""
prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message)
      output_path="${2:-}"
      shift 2
      ;;
    --skip-git-repo-check)
      shift
      ;;
    exec)
      shift
      ;;
    *)
      prompt="$1"
      shift
      ;;
  esac
done

if [[ -z "$output_path" ]]; then
  printf 'missing --output-last-message\n' >&2
  exit 65
fi

if [[ "$prompt" != *"alpha task input"* ]]; then
  printf 'prompt did not include input text\n' >&2
  exit 66
fi

mkdir -p "$(dirname "$output_path")"
printf 'builder final from fake codex\n' > "$output_path"
printf '{"type":"agent_message","role":"builder","text":"builder stdout event"}\n'
printf 'builder stderr event' >&2
EOF
chmod +x "$fake_codex"

claspc_bin="$(
  CLASP_CLASPC= CLASPC_BIN= CLASP_PROJECT_ROOT="$project_root" \
    "$project_root/scripts/resolve-claspc.sh"
)"
demo_path="$project_root/examples/agent-loop-scenario/AgentLoopHarness.clasp"
handoff_demo_path="$project_root/examples/agent-loop-scenario/AgentHandoffHarness.clasp"

if grep -F '"bash"' "$demo_path" >/dev/null; then
  fail "agent loop scenario should invoke direct executables, not shell wrappers"
fi

if grep -E 'clasp-swarm|claspc[[:space:]]+swarm' "$demo_path" >/dev/null; then
  fail "agent loop scenario should not use first-class compiler swarm commands"
fi

if grep -F 'import Process' "$demo_path" >/dev/null || grep -F 'import AgentRuntime' "$demo_path" >/dev/null; then
  fail "agent loop runtime harness must stay single-source"
fi

if grep -F 'import AgentRuntime' "$handoff_demo_path" >/dev/null; then
  fail "agent handoff runtime harness must stay single-source"
fi

grep -F 'agentTaskQueue' "$demo_path" >/dev/null
grep -F 'workLimit = 2' "$demo_path" >/dev/null
grep -F 'processAgentTaskQueue' "$demo_path" >/dev/null
grep -F 'agentReadTextOrEmpty' "$demo_path" >/dev/null
grep -F 'agentWriteTextStatus' "$demo_path" >/dev/null
grep -F 'agentAppendEvent' "$demo_path" >/dev/null
grep -F 'workspaceAppendText' "$project_root/examples/agent-loop-scenario/AgentRuntime.clasp" >/dev/null
grep -F 'runMonitoredLogged' "$demo_path" >/dev/null
grep -F 'monitoredCommandSpec' "$project_root/examples/agent-loop-scenario/Process.clasp" >/dev/null
grep -F 'workspaceWriteText record.root record.statusPath' "$project_root/examples/agent-loop-scenario/Process.clasp" >/dev/null
grep -F 'workspaceAppendText commandSpecValue.root spec.eventLogPath' "$project_root/examples/agent-loop-scenario/Process.clasp" >/dev/null
grep -F '"exec"' "$demo_path" >/dev/null
grep -F '"--output-last-message"' "$demo_path" >/dev/null
grep -F 'record AgentHandoffSnapshot' "$project_root/examples/agent-loop-scenario/AgentRuntime.clasp" >/dev/null
grep -F 'type AgentHandoffClaim' "$project_root/examples/agent-loop-scenario/AgentRuntime.clasp" >/dev/null
grep -F 'agentHandoffPersist' "$project_root/examples/agent-loop-scenario/AgentRuntime.clasp" >/dev/null
grep -F 'agentHandoffLoad' "$project_root/examples/agent-loop-scenario/AgentRuntime.clasp" >/dev/null
grep -F 'match tryDecode AgentHandoffSnapshot raw' "$project_root/examples/agent-loop-scenario/AgentRuntime.clasp" >/dev/null
grep -F 'agentHandoffCompleteTask' "$project_root/examples/agent-loop-scenario/AgentRuntime.clasp" >/dev/null
grep -F 'match tryDecode AgentHandoffSnapshot raw' "$handoff_demo_path" >/dev/null
grep -F 'runVerifierStep restoredForVerifier' "$handoff_demo_path" >/dev/null

(
  cd "$project_root"
  timeout "$timeout_secs" "$claspc_bin" --json check "$demo_path" | grep -F '"status":"ok"' >/dev/null
  timeout "$timeout_secs" "$claspc_bin" run "$demo_path" -- "$workspace_root" "$fake_codex" >"$run_output"
)

node - "$run_output" "$workspace_root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const [outputPath, workspaceRoot] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(outputPath, "utf8"));
const persisted = JSON.parse(fs.readFileSync(path.join(workspaceRoot, "agent-loop-status.json"), "utf8"));
const builderRun = JSON.parse(fs.readFileSync(path.join(workspaceRoot, "artifacts/builder.run.json"), "utf8"));
const verifierRun = JSON.parse(fs.readFileSync(path.join(workspaceRoot, "artifacts/verifier.run.json"), "utf8"));
const eventLines = fs
  .readFileSync(path.join(workspaceRoot, "agent-loop-events.jsonl"), "utf8")
  .trim()
  .split(/\n/)
  .filter(Boolean)
  .map((line) => JSON.parse(line));
const runEvents = fs
  .readFileSync(path.join(workspaceRoot, "agent-loop-runs.jsonl"), "utf8")
  .trim()
  .split(/\n/)
  .filter(Boolean)
  .map((line) => JSON.parse(line));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function readText(relativePath) {
  return fs.readFileSync(path.join(workspaceRoot, relativePath), "utf8");
}

assert(report.loopId === "ordinary-clasp-safe-agent-loop", "loop id changed");
assert(report.finalStatus === "completed-pass", `unexpected final status ${report.finalStatus}`);
assert(report.completed === true, "loop should complete");
assert(JSON.stringify(report) === JSON.stringify(persisted), "final status should be durably persisted");
assert(report.runEventLogPath === "agent-loop-runs.jsonl", "run event log path should be reported");
assert(report.builderRunStatusPath === "artifacts/builder.run.json", "builder run status path should be reported");
assert(report.verifierRunStatusPath === "artifacts/verifier.run.json", "verifier run status path should be reported");

assert(report.workLimit === 2, "ordinary loop should process a bounded batch");
assert(report.processedCount === 2, "ordinary loop should process two queued work items");
assert(Array.isArray(report.taskQueue) && report.taskQueue.length === 2, "task queue should be reported");
assert(report.taskQueue[0].taskId === "task-builder", "builder task should be first");
assert(report.taskQueue[1].taskId === "task-verifier", "verifier task should be second");
assert(JSON.stringify(report.processedTaskIds) === JSON.stringify(["task-builder", "task-verifier"]), "processed task ids changed");
assert(Array.isArray(report.remainingTaskIds) && report.remainingTaskIds.length === 0, "all queued tasks should fit the work limit");
assert(Array.isArray(report.outcomes) && report.outcomes.length === 2, "task outcomes should be recorded");
assert(report.outcomes[0].taskId === "task-builder" && report.outcomes[0].ok === true, "builder outcome missing");
assert(report.outcomes[1].taskId === "task-verifier" && report.outcomes[1].ok === true, "verifier outcome missing");

assert(report.inputText === "alpha task input\n", "input file should be inspected");
assert(report.builder.ok === true, "builder should pass");
assert(report.builder.status === "completed-pass", `unexpected builder status ${report.builder.status}`);
assert(report.builder.exitCode === 0, "builder exit should be zero");
assert(report.builder.stdout.includes('"role":"builder"'), "builder stdout should be captured");
assert(report.builder.stderr === "builder stderr event", "builder stderr should be captured");
assert(report.builder.finalText === "builder final from fake codex\n", "builder final should be captured");
assert(JSON.stringify(report.builder.runRecord) === JSON.stringify(builderRun), "builder monitored run should be durably persisted");
assert(builderRun.runId === "builder-codex", "builder run id changed");
assert(builderRun.role === "builder", "builder run role changed");
assert(builderRun.status === "completed-pass", "builder run status should pass");
assert(builderRun.statusPath === "artifacts/builder.run.json", "builder run status path changed");
assert(builderRun.eventLogPath === "agent-loop-runs.jsonl", "builder run event log path changed");
assert(builderRun.cwd === "." && builderRun.timeoutMs === 5000, "builder command envelope should be durable");
assert(Array.isArray(builderRun.command) && builderRun.command[0] === path.join(path.dirname(outputPath), "codex"), "builder should invoke the fake codex executable directly");
assert(builderRun.command.includes("exec"), "builder command should use codex exec directly");
assert(builderRun.command.includes("--output-last-message"), "builder command should persist the final Codex message");

assert(report.verifier.ok === true, "verifier should pass");
assert(report.verifier.status === "completed-pass", `unexpected verifier status ${report.verifier.status}`);
assert(report.verifier.exitCode === 0, "verifier exit should be zero");
assert(report.verifier.stdout.includes('"ok":true'), "verifier stdout should contain structured JSON");
assert(report.verifier.timedOut === false, "verifier should not time out");
assert(JSON.stringify(report.verifier.runRecord) === JSON.stringify(verifierRun), "verifier monitored run should be durably persisted");
assert(verifierRun.runId === "verifier-check", "verifier run id changed");
assert(verifierRun.role === "verifier", "verifier run role changed");
assert(verifierRun.status === "completed-pass", "verifier run status should pass");
assert(verifierRun.statusPath === "artifacts/verifier.run.json", "verifier run status path changed");
assert(verifierRun.eventLogPath === "agent-loop-runs.jsonl", "verifier run event log path changed");
assert(Array.isArray(verifierRun.command) && verifierRun.command[0] === "node", "verifier should invoke node directly");

assert(readText("artifacts/builder.prompt.md").includes("alpha task input"), "builder prompt should persist");
assert(readText("artifacts/builder.final.txt") === report.builder.finalText, "builder final artifact should persist");
assert(readText("src/output.txt") === report.outputText, "bounded output should persist");
assert(report.outputText.includes("alpha task input"), "bounded output should include inspected input");
assert(report.outputText.includes("builder final from fake codex"), "bounded output should include builder final");
assert(report.summary === "loop=ordinary-clasp-safe-agent-loop builder=completed-pass verifier=completed-pass final=completed-pass", "summary changed");

assert(eventLines.length === 4, "event log should contain durable lifecycle events");
assert(eventLines.some((event) => event.kind === "loop-started"), "loop start event missing");
assert(eventLines.filter((event) => event.kind === "step-completed").length === 2, "step completion events missing");
assert(eventLines.some((event) => event.kind === "loop-completed" && event.status === "completed-pass"), "loop completion event missing");
assert(JSON.stringify(eventLines) === JSON.stringify(report.events), "event log should match report events");

assert(runEvents.length === 4, "run event log should contain durable builder/verifier start and completion events");
for (const id of ["builder-codex", "verifier-check"]) {
  const startIndex = runEvents.findIndex((event) => event.runId === id && event.kind === "run-started");
  const finishIndex = runEvents.findIndex((event) => event.runId === id && event.kind === "run-completed");
  assert(startIndex >= 0, `${id} start event should persist`);
  assert(finishIndex > startIndex, `${id} completion event should follow start event`);
}
assert(runEvents.some((event) => event.runId === "builder-codex" && event.status === "completed-pass"), "builder run completion event missing");
assert(runEvents.some((event) => event.runId === "verifier-check" && event.status === "completed-pass"), "verifier run completion event missing");
NODE

(
  cd "$project_root"
  timeout "$timeout_secs" "$claspc_bin" --json check "$handoff_demo_path" | grep -F '"status":"ok"' >/dev/null
  timeout "$timeout_secs" "$claspc_bin" run "$handoff_demo_path" -- "$handoff_workspace" >"$handoff_output"
)

node - "$handoff_output" "$handoff_workspace" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const [outputPath, workspaceRoot] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(outputPath, "utf8"));
const snapshot = JSON.parse(fs.readFileSync(path.join(workspaceRoot, "handoff/workflow-snapshot.json"), "utf8"));
const events = fs
  .readFileSync(path.join(workspaceRoot, "handoff/workflow-events.jsonl"), "utf8")
  .trim()
  .split(/\n/)
  .filter(Boolean)
  .map((line) => JSON.parse(line));
const builderResult = JSON.parse(fs.readFileSync(path.join(workspaceRoot, "artifacts/builder-result.json"), "utf8"));
const verifierResult = JSON.parse(fs.readFileSync(path.join(workspaceRoot, "artifacts/verifier-result.json"), "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function readText(relativePath) {
  return fs.readFileSync(path.join(workspaceRoot, relativePath), "utf8");
}

assert(report.workflowId === "ordinary-clasp-agent-handoff", "handoff workflow id changed");
assert(report.finalStatus === "completed", `unexpected handoff final status ${report.finalStatus}`);
assert(report.recoveredCorruptSnapshot === true, "handoff load should recover from a corrupt durable snapshot");
assert(report.restoredAfterBuilder === true, "verifier should resume from a persisted builder snapshot");
assert(report.resumedTaskId === "handoff-verifier", "verifier should claim the second task after resume");
assert(JSON.stringify(report.completedTaskIds) === JSON.stringify(["handoff-builder", "handoff-verifier"]), "completed task ids changed");
assert(JSON.stringify(report.tasks) === JSON.stringify(snapshot.tasks), "reported tasks should match durable snapshot");
assert(JSON.stringify(report.completedTaskIds) === JSON.stringify(snapshot.completedTaskIds), "reported completed ids should match durable snapshot");
assert(snapshot.status === "completed", "durable snapshot should project completed status");
assert(snapshot.currentTaskId === "", "durable snapshot should not leave a claimed task active");
assert(snapshot.snapshotPath === "handoff/workflow-snapshot.json", "snapshot path should be durable");
assert(snapshot.eventLogPath === "handoff/workflow-events.jsonl", "event log path should be durable");

const builderTask = snapshot.tasks.find((task) => task.taskId === "handoff-builder");
const verifierTask = snapshot.tasks.find((task) => task.taskId === "handoff-verifier");
assert(builderTask && verifierTask, "snapshot should contain both handoff tasks");
assert(builderTask.status === "completed-pass", "builder task should complete");
assert(verifierTask.status === "completed-pass", "verifier task should complete");
assert(builderTask.detail === "artifacts/builder-note.txt", "builder detail should point at artifact");
assert(verifierTask.detail === "artifacts/verifier-note.txt", "verifier detail should point at artifact");
assert(builderTask.updatedAtMs > 0 && verifierTask.updatedAtMs >= builderTask.updatedAtMs, "task timestamps should be projected");

assert(readText("inputs/task.txt") === "handoff input from planner\n", "planner input should persist");
assert(report.builderOutput.includes("handoff input from planner"), "builder artifact should include planner input");
assert(report.verifierOutput.includes(report.builderOutput), "verifier artifact should consume builder artifact after resume");
assert(readText("artifacts/builder-note.txt") === report.builderOutput, "builder artifact path should be readable");
assert(readText("artifacts/verifier-note.txt") === report.verifierOutput, "verifier artifact path should be readable");

assert(builderResult.kind === "task-result" && builderResult.role === "builder", "builder result should be structured");
assert(verifierResult.kind === "task-result" && verifierResult.role === "verifier", "verifier result should be structured");
assert(builderResult.status === "completed-pass", "builder result status should pass");
assert(verifierResult.status === "completed-pass", "verifier result status should pass");

assert(events.length === 6, "handoff event log should contain create, claim, complete, and close events");
assert(events[0].kind === "handoff-created" && events[0].role === "planner", "planner creation event missing");
assert(events.filter((event) => event.kind === "task-claimed").map((event) => event.role).join(",") === "builder,verifier", "claim event order should show handoff");
assert(events.filter((event) => event.kind === "task-completed").length === 2, "task completion events missing");
assert(events.some((event) => event.kind === "handoff-completed" && event.status === "completed"), "handoff completion event missing");
assert(report.summary === "workflow=ordinary-clasp-agent-handoff status=completed resumed=handoff-verifier", "handoff summary changed");
NODE

printf 'agent-loop-scenario-ok\n'
