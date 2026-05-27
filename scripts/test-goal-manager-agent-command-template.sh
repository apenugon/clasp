#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_GOAL_MANAGER_AGENT_COMMAND_TEMPLATE_TIMEOUT_SECS:-180}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_GOAL_MANAGER_AGENT_COMMAND_TEMPLATE_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-goal-manager-agent-command-template.XXXXXX")"
test_root_abs="$(cd "$test_root" && pwd -P)"
state_root="$test_root_abs/state"
workspace_root="$test_root_abs/workspace"
fake_agent="$test_root_abs/generic-agent"
fake_child_claspc="$test_root_abs/fake-child-claspc"
fake_codex="$test_root_abs/codex-must-not-run"
fake_goal_manager="$test_root_abs/swarm-goal-manager"
fake_ensure_claspc="$test_root_abs/fake-ensure-claspc"
agent_log="$test_root_abs/agent-invocations.jsonl"
child_log="$test_root_abs/child-env.jsonl"
codex_marker="$test_root_abs/codex-was-used"
output_path="$test_root_abs/output.json"
status_path="$test_root_abs/status.json"

cleanup() {
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root_abs" >&2
  else
    rm -rf "$test_root_abs" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

json_string() {
  node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

cat >"$fake_agent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

role=""
report_path=""
prompt_path=""
workspace_root="."
schema_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)
      role="${2:-}"
      shift 2
      ;;
    --report)
      report_path="${2:-}"
      shift 2
      ;;
    --prompt-path)
      prompt_path="${2:-}"
      shift 2
      ;;
    --workspace)
      workspace_root="${2:-}"
      shift 2
      ;;
    --schema)
      schema_path="${2:-}"
      shift 2
      ;;
    --model|--reasoning|--sandbox)
      shift 2
      ;;
    *)
      printf 'unexpected generic-agent argument: %s\n' "$1" >&2
      exit 64
      ;;
  esac
done

if [[ "$role" != "planner" || -z "$report_path" || -z "$prompt_path" ]]; then
  printf 'generic manager agent expected planner role with report and prompt path\n' >&2
  exit 65
fi

prompt="$(cat "$prompt_path")"
if [[ "$prompt" != *"planner subagent"* ]]; then
  printf 'planner prompt was not supplied through the generic template\n' >&2
  exit 66
fi
if [[ "$prompt" != *"Plan 1-1 bounded tasks with explicit dependencies and task prompts."* ]]; then
  printf 'planner prompt missing task budget contract\n' >&2
  exit 67
fi
if [[ "$prompt" != *"Planner context pack:"* || "$prompt" != *"task: planner-1"* ]]; then
  printf 'planner prompt missing native context pack\n' >&2
  exit 68
fi
if [[ "$prompt" != *"artifact search matches:"* ]]; then
  printf 'planner prompt missing artifact search context\n' >&2
  exit 69
fi

mkdir -p "$(dirname "$report_path")" "$workspace_root"
printf '{"role":%s,"reportPath":%s,"promptPath":%s,"schemaPath":%s,"workspaceRoot":%s}\n' \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$role")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$report_path")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$prompt_path")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$schema_path")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$workspace_root")" \
  >> "${CLASP_TEST_AGENT_LOG:?}"

cat >"$report_path" <<'JSON'
{"objectiveSummary":"Prove the manager can plan with a generic non-Codex backend.","strategy":"Use one child loop task while preserving provider-neutral child agent command configuration.","tasks":[{"taskId":"provider-neutral-child","role":"generic-agent-proof","detail":"Run a child loop without requiring Codex as the swarm agent backend.","dependencies":[],"taskPrompt":"Verify the manager passes generic agent command templates into child loops.","coordinationFocus":["provider-neutral-agent","child-loop-env"]}],"testsRun":["generic-manager-planner-template"],"residualRisks":[]}
JSON
EOF
chmod +x "$fake_agent"

cat >"$fake_child_claspc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

decode_json_env() {
  node -e 'const raw = process.env[process.argv[1]] || "\"\""; process.stdout.write(JSON.parse(raw));' "$1"
}

if [[ "${1:-}" != "run" ]]; then
  printf 'fake child claspc expected run, got: %s\n' "$*" >&2
  exit 70
fi

state_root=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--" ]]; then
    state_root="${2:-}"
    break
  fi
  shift
done

if [[ -z "$state_root" ]]; then
  printf 'missing child loop state root\n' >&2
  exit 71
fi

if [[ "${CLASP_LOOP_AGENT_COMMAND_JSON:-}" != "${CLASP_TEST_EXPECT_CHILD_AGENT_COMMAND_JSON:-}" ]]; then
  printf 'child loop did not receive the generic agent command template\n' >&2
  exit 72
fi
if [[ "${CLASP_LOOP_AGENT_BIN_JSON:-}" != "${CLASP_TEST_EXPECT_AGENT_BIN_JSON:-}" ]]; then
  printf 'child loop did not receive the generic agent binary\n' >&2
  exit 73
fi
if [[ "${CLASP_LOOP_AGENT_MEMORY_MB_JSON:-}" != "2048" ]]; then
  printf 'child loop did not receive the generic agent memory cap\n' >&2
  exit 77
fi
if [[ "${CLASP_LOOP_BUILDER_MEMORY_MB_JSON:-}" != "1024" ]]; then
  printf 'child loop did not receive the builder memory cap\n' >&2
  exit 78
fi
if [[ "${CLASP_LOOP_VERIFIER_MEMORY_MB_JSON:-}" != "1536" ]]; then
  printf 'child loop did not receive the verifier memory cap\n' >&2
  exit 79
fi
if [[ -n "${CLASP_MANAGER_BENCHMARK_COMMAND_JSON:-}" ]]; then
  printf 'child loop inherited manager benchmark command\n' >&2
  exit 80
fi

task_file="$(decode_json_env CLASP_LOOP_TASK_FILE_JSON)"
workspace_root="$(decode_json_env CLASP_LOOP_WORKSPACE_JSON)"
if [[ ! -f "$task_file" ]]; then
  printf 'child loop task file missing: %s\n' "$task_file" >&2
  exit 81
fi
if [[ "$(cat "$task_file")" != *"generic agent command templates"* ]]; then
  printf 'child loop task prompt did not come from generic planner report\n' >&2
  exit 82
fi

mkdir -p "$workspace_root/notes" "$workspace_root/.clasp-test-tmp" "$state_root"
printf 'provider-neutral-child-ok\n' >"$workspace_root/workspace.txt"
printf 'provider-neutral-child-ok\n' >"$workspace_root/notes/child-artifact.txt"
printf 'transient-noise\n' >"$workspace_root/.clasp-test-tmp/noise.txt"

printf '{"stateRoot":%s,"workspaceRoot":%s,"agentCommandJson":%s,"agentBinJson":%s,"codexBinJson":%s,"agentMemoryMb":%s,"builderMemoryMb":%s,"verifierMemoryMb":%s}\n' \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$state_root")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$workspace_root")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "${CLASP_LOOP_AGENT_COMMAND_JSON:-}")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "${CLASP_LOOP_AGENT_BIN_JSON:-}")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "${CLASP_LOOP_CODEX_BIN_JSON:-}")" \
  "$(node -e 'process.stdout.write(JSON.stringify(Number(process.argv[1])))' "${CLASP_LOOP_AGENT_MEMORY_MB_JSON:-0}")" \
  "$(node -e 'process.stdout.write(JSON.stringify(Number(process.argv[1])))' "${CLASP_LOOP_BUILDER_MEMORY_MB_JSON:-0}")" \
  "$(node -e 'process.stdout.write(JSON.stringify(Number(process.argv[1])))' "${CLASP_LOOP_VERIFIER_MEMORY_MB_JSON:-0}")" \
  >> "${CLASP_TEST_CHILD_ENV_LOG:?}"

cat >"$state_root/state.json" <<'JSON'
{"attempt":1,"phase":"completed","verdict":"pass","completed":true,"builderRuns":1,"verifierRuns":1,"healthy":true,"needsAttention":false,"attentionReason":"","final":true}
JSON
cat >"$state_root/feedback.json" <<'JSON'
{"verdict":"pass","summary":"generic child loop completed","findings":[],"tests_run":["generic child loop env"],"follow_up":[],"capability_statuses":[{"name":"provider_neutral_goal_manager","status":"pass","evidence":["GoalManager passed CLASP_LOOP_AGENT_COMMAND_JSON to the child loop"],"blocking_gaps":[],"required_closure":[]}]}
JSON
printf 'generic child loop completed\n'
EOF
chmod +x "$fake_child_claspc"

cat >"$fake_codex" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'codex backend should not be used in provider-neutral manager test\n' >"$(printf '%q' "$codex_marker")"
exit 79
EOF
chmod +x "$fake_codex"

cp "$project_root/scripts/test-goal-manager-fixture-manager.mjs" "$fake_goal_manager"
chmod +x "$fake_goal_manager"

cat >"$fake_ensure_claspc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'test fixture intentionally disables full GoalManager native compilation\n' >&2
exit 90
EOF
chmod +x "$fake_ensure_claspc"

claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN CLASP_PROJECT_ROOT="$project_root" "$project_root/scripts/resolve-claspc.sh")"
goal_manager_bin="$(
  XDG_CACHE_HOME="$test_root_abs/xdg-cache" \
  CLASP_GOAL_MANAGER_CLASPC_BIN="$fake_ensure_claspc" \
  CLASP_GOAL_MANAGER_COMPILE_MANAGED="${CLASP_GOAL_MANAGER_COMPILE_MANAGED:-0}" \
  CLASP_GOAL_MANAGER_COMPILE_TIMEOUT_SECS="${CLASP_GOAL_MANAGER_COMPILE_TIMEOUT_SECS:-1}" \
  CLASP_GOAL_MANAGER_COMPILE_ATTEMPTS="${CLASP_GOAL_MANAGER_COMPILE_ATTEMPTS:-1}" \
  CLASP_GOAL_MANAGER_ALLOW_STALE_ON_COMPILE_FAILURE="${CLASP_GOAL_MANAGER_ALLOW_STALE_ON_COMPILE_FAILURE:-1}" \
  CLASP_GOAL_MANAGER_ALLOW_UNMANAGED_STALE="${CLASP_GOAL_MANAGER_ALLOW_UNMANAGED_STALE:-1}" \
  CLASP_GOAL_MANAGER_COMPILE_MEMORY_MB="${CLASP_GOAL_MANAGER_COMPILE_MEMORY_MB:-12288}" \
  CLASP_GOAL_MANAGER_COMPILE_MIN_AVAILABLE_MEMORY_MB="${CLASP_GOAL_MANAGER_COMPILE_MIN_AVAILABLE_MEMORY_MB:-16384}" \
  CLASP_NATIVE_BUNDLE_JOBS="${CLASP_NATIVE_BUNDLE_JOBS:-1}" \
  CLASP_NATIVE_IMAGE_SECTION_JOBS="${CLASP_NATIVE_IMAGE_SECTION_JOBS:-1}" \
  CLASP_NATIVE_JOBS_MAX="${CLASP_NATIVE_JOBS_MAX:-1}" \
  CLASP_NATIVE_RELAXED_BUILD_PLAN_CACHE="${CLASP_NATIVE_RELAXED_BUILD_PLAN_CACHE:-1}" \
  "$project_root/scripts/ensure-goal-manager-binary.sh" \
    --alias "$fake_goal_manager"
)"
agent_bin_json="$(json_string "$claspc_bin")"
codex_bin_json="$(json_string "$fake_codex")"
child_claspc_json="$(json_string "$fake_child_claspc")"
workspace_json="$(json_string "$workspace_root")"
project_root_json="$(json_string "$project_root")"
goal_json="$(json_string "Prove GoalManager can run with provider-neutral planner and child agent command templates.")"

agent_command_json="$(
  node - "$project_root/examples/swarm-native/LocalPlanner.clasp" <<'NODE'
const localPlannerPath = process.argv[2];
process.stdout.write(JSON.stringify([
  "{agent_bin}",
  "run",
  localPlannerPath,
  "--",
  "--role",
  "{role}",
  "--schema",
  "{schema_path}",
  "--report",
  "{report_path}",
  "--prompt-path",
  "{prompt_path}",
  "--workspace",
  "{workspace_root}"
]));
NODE
)"

grep -F 'clasp-local-planner' "$project_root/examples/swarm-native/LocalPlanner.clasp" >/dev/null

mkdir -p "$workspace_root"
XDG_CACHE_HOME="$test_root_abs/xdg-cache" \
CLASP_LOOP_AGENT_BIN_JSON="$agent_bin_json" \
CLASP_LOOP_CODEX_BIN_JSON="$codex_bin_json" \
CLASP_LOOP_AGENT_COMMAND_JSON="$agent_command_json" \
CLASP_MANAGER_PLANNER_AGENT_COMMAND_JSON="$agent_command_json" \
CLASP_LOOP_AGENT_MEMORY_MB_JSON='2048' \
CLASP_LOOP_BUILDER_MEMORY_MB_JSON='1024' \
CLASP_LOOP_VERIFIER_MEMORY_MB_JSON='1536' \
CLASP_MANAGER_CLASPC_BIN_JSON="$child_claspc_json" \
CLASP_MANAGER_PROJECT_ROOT_JSON="$project_root_json" \
CLASP_LOOP_WORKSPACE_JSON="$workspace_json" \
CLASP_MANAGER_GOAL_JSON="$goal_json" \
CLASP_MANAGER_OBJECTIVE_ID_JSON='"provider-neutral-manager"' \
CLASP_MANAGER_MAX_TASKS_JSON='1' \
CLASP_MANAGER_MAX_WAVES_JSON='1' \
CLASP_MANAGER_CHILD_AWAIT_TIMEOUT_MS_JSON='10000' \
CLASP_LOOP_WATCH_POLL_MS_JSON='20' \
CLASP_MANAGER_TRACE_JSON='true' \
CLASP_MANAGER_TASK_WORKSPACE_CACHE_MAX_MB_JSON='16' \
CLASP_MANAGER_TASK_BASELINE_CACHE_MAX_MB_JSON='16' \
CLASP_MANAGER_FEEDBACK_LOOP_BASELINE_CACHE_MAX_MB_JSON='16' \
CLASP_MANAGER_CHILD_LOOP_BASELINE_CACHE_TOTAL_MAX_MB_JSON='16' \
CLASP_MANAGER_CHILD_LOOP_XDG_CACHE_TOTAL_MAX_MB_JSON='32' \
CLASP_MANAGER_ARTIFACTS_CACHE_MAX_MB_JSON='16' \
CLASP_MANAGER_XDG_CACHE_MAX_MB_JSON='32' \
CLASP_TEST_AGENT_LOG="$agent_log" \
CLASP_TEST_CHILD_ENV_LOG="$child_log" \
CLASP_TEST_EXPECT_CHILD_AGENT_COMMAND_JSON="$agent_command_json" \
CLASP_TEST_EXPECT_AGENT_BIN_JSON="$agent_bin_json" \
timeout "$timeout_secs" "$goal_manager_bin" "$state_root" >"$output_path"

CLASP_MANAGER_COMMAND=status \
timeout "$timeout_secs" "$goal_manager_bin" "$state_root" >"$status_path"

node - "$output_path" "$status_path" "$agent_log" "$child_log" "$state_root" "$workspace_root" "$codex_marker" "$agent_command_json" "$agent_bin_json" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [
  outputPath,
  statusPath,
  agentLogPath,
  childLogPath,
  stateRoot,
  workspaceRoot,
  codexMarker,
  expectedAgentCommandJson,
  expectedAgentBinJson,
] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function readJson(pathValue) {
  return JSON.parse(fs.readFileSync(pathValue, "utf8"));
}

function readJsonLines(pathValue) {
  return fs
    .readFileSync(pathValue, "utf8")
    .trim()
    .split(/\n/)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

const output = readJson(outputPath);
const status = readJson(statusPath);
const planner = readJson(path.join(stateRoot, "planner-1.json"));
const feedback = readJson(path.join(stateRoot, "feedback.json"));
const agentInvocations = readJsonLines(agentLogPath);
const childInvocations = readJsonLines(childLogPath);

assert(output.state?.phase === "completed", `manager output phase ${output.state?.phase}`);
assert(output.state?.verdict === "pass" && output.state?.final === true, "manager output should finish with pass");
assert(status.state?.phase === "completed", `manager status phase ${status.state?.phase}`);
assert(status.state?.verdict === "pass" && status.state?.final === true, "manager status should persist pass");
assert(status.plannedTaskIds.includes("provider-neutral-child"), "manager should track the generic planner task");
assert(status.completedTaskIds.includes("provider-neutral-child"), "planned child task should complete");
assert(status.objectiveProjectedStatus === "completed", `objective projected ${status.objectiveProjectedStatus}`);
assert(planner.tasks.length === 1 && planner.tasks[0].taskId === "provider-neutral-child", "planner report should come from generic planner");
assert(planner.tasks[0].taskPrompt.includes("native planner context pack"), "Clasp planner task should consume native context pack evidence");
assert(planner.tasks[0].coordinationFocus.includes("native-context-pack"), "Clasp planner task should tag native context-pack coordination");
assert(planner.testsRun.includes("clasp-local-planner-context-pack"), "Clasp planner report should record context-pack coverage");
assert(feedback.verdict === "pass", `feedback verdict ${feedback.verdict}`);
assert(agentInvocations.length === 1, `expected one generic planner invocation, saw ${agentInvocations.length}`);
assert(agentInvocations[0].role === "planner", "generic agent should be used for planner role");
assert(agentInvocations[0].backend === "clasp-local-planner", "GoalManager should use the Clasp-native planner backend");
assert(childInvocations.length === 1, `expected one child loop invocation, saw ${childInvocations.length}`);
assert(childInvocations[0].agentCommandJson === expectedAgentCommandJson, "child should receive generic agent command JSON");
assert(childInvocations[0].agentBinJson === expectedAgentBinJson, "child should receive generic agent binary JSON");
assert(childInvocations[0].agentMemoryMb === 2048, `agent memory cap ${childInvocations[0].agentMemoryMb}`);
assert(childInvocations[0].builderMemoryMb === 1024, `builder memory cap ${childInvocations[0].builderMemoryMb}`);
assert(childInvocations[0].verifierMemoryMb === 1536, `verifier memory cap ${childInvocations[0].verifierMemoryMb}`);
assert(fs.readFileSync(path.join(workspaceRoot, ".clasp-task-workspaces", "provider-neutral-child", "workspace.txt"), "utf8").trim() === "provider-neutral-child-ok", "child workspace should be written");
assert(!fs.existsSync(codexMarker), "Codex fallback backend should not be invoked");
NODE

printf 'goal-manager-agent-command-template-ok\n'
