#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_GOAL_MANAGER_DEFAULT_PLANNER_TIMEOUT_SECS:-180}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_GOAL_MANAGER_DEFAULT_PLANNER_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-goal-manager-default-planner-command.XXXXXX")"
test_root_abs="$(cd "$test_root" && pwd -P)"
state_root="$test_root_abs/state"
workspace_root="$test_root_abs/workspace"
fake_codex="$test_root_abs/fake-codex"
fake_child_claspc="$test_root_abs/fake-child-claspc"
fake_goal_manager="$test_root_abs/swarm-goal-manager"
fake_ensure_claspc="$test_root_abs/fake-ensure-claspc"
planner_log="$test_root_abs/planner.jsonl"
child_log="$test_root_abs/child.jsonl"
stdin_marker="$test_root_abs/planner-used-stdin"
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

require_bootstrap_planner_pattern() {
  local pattern="$1"

  if ! grep -F -- "$pattern" "$project_root/examples/swarm-native/GoalManagerBootstrapPlanner.clasp" >/dev/null; then
    printf 'default planner source missing native context pack pattern: %s\n' "$pattern" >&2
    exit 67
  fi
}

require_bootstrap_planner_pattern 'plannerContextSectionFor wave'
require_bootstrap_planner_pattern 'taskContextPack (plannerHandleForWave wave)'
require_bootstrap_planner_pattern 'plannerContextSectionFor wave,'

cat >"$fake_codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

workspace_root="."
report_path=""
schema_path=""
prompt=""
prompt_from_stdin=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    exec)
      shift
      ;;
    --json|--skip-git-repo-check|--ephemeral)
      shift
      ;;
    --cd)
      workspace_root="${2:-}"
      shift 2
      ;;
    -m|-c|--sandbox)
      shift 2
      ;;
    --output-schema)
      schema_path="${2:-}"
      shift 2
      ;;
    -o|--output-last-message)
      report_path="${2:-}"
      shift 2
      ;;
    *)
      prompt="$1"
      shift
      ;;
  esac
done

if [[ "$prompt" == "-" ]]; then
  prompt_from_stdin=1
  prompt="$(cat)"
fi

if [[ "$prompt_from_stdin" == "1" ]]; then
  printf 'default planner command should pass the prompt as an argument, not through stdin\n' >&2
  printf 'stdin\n' >"${CLASP_TEST_STDIN_MARKER:?}"
  exit 64
fi

if [[ -z "$report_path" || "$prompt" != *"planner subagent"* ]]; then
  printf 'fake planner expected report path and planner prompt\n' >&2
  exit 65
fi

if [[ "$prompt" != *"Plan 1-1 bounded tasks with explicit dependencies and task prompts."* ]]; then
  printf 'fake planner prompt missing task budget contract\n' >&2
  exit 66
fi

mkdir -p "$(dirname "$report_path")" "$workspace_root"
printf '{"backend":"fake-codex-default","promptFromStdin":false,"reportPath":%s,"schemaPath":%s,"workspaceRoot":%s}\n' \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$report_path")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$schema_path")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$workspace_root")" \
  >>"${CLASP_TEST_PLANNER_LOG:?}"

cat >"$report_path" <<'JSON'
{"objectiveSummary":"Prove the default GoalManager planner path is shell-free.","strategy":"Use one child loop task after a fake Codex planner receives the prompt directly as an argument.","tasks":[{"taskId":"default-planner-child","role":"planner-command-proof","detail":"Complete a child loop planned by the default planner command path.","dependencies":[],"taskPrompt":"Verify the default planner command path passes prompts without a shell stdin shim.","coordinationFocus":["default-planner","shell-free"]}],"testsRun":["default-planner-command"],"residualRisks":[]}
JSON
EOF
chmod +x "$fake_codex"

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

task_file="$(decode_json_env CLASP_LOOP_TASK_FILE_JSON)"
workspace_root="$(decode_json_env CLASP_LOOP_WORKSPACE_JSON)"

if [[ ! -f "$task_file" || "$(cat "$task_file")" != *"shell-free"* ]]; then
  printf 'child loop task prompt did not come from default planner report\n' >&2
  exit 72
fi

mkdir -p "$workspace_root/notes" "$state_root"
printf 'default-planner-child-ok\n' >"$workspace_root/workspace.txt"
printf 'default-planner-child-ok\n' >"$workspace_root/notes/child-artifact.txt"
printf '{"stateRoot":%s,"workspaceRoot":%s,"agentCommandJson":%s}\n' \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$state_root")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$workspace_root")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "${CLASP_LOOP_AGENT_COMMAND_JSON:-}")" \
  >>"${CLASP_TEST_CHILD_LOG:?}"

cat >"$state_root/state.json" <<'JSON'
{"attempt":1,"phase":"completed","verdict":"pass","completed":true,"builderRuns":1,"verifierRuns":1,"healthy":true,"needsAttention":false,"attentionReason":"","final":true}
JSON
cat >"$state_root/feedback.json" <<'JSON'
{"verdict":"pass","summary":"default planner child completed","findings":[],"tests_run":["default planner child env"],"follow_up":[],"capability_statuses":[{"name":"shell_free_default_planner","status":"pass","evidence":["GoalManager default planner path passed prompt as an argument"],"blocking_gaps":[],"required_closure":[]}]}
JSON
printf 'default planner child completed\n'
EOF
chmod +x "$fake_child_claspc"

cp "$project_root/scripts/test-goal-manager-fixture-manager.mjs" "$fake_goal_manager"
chmod +x "$fake_goal_manager"

cat >"$fake_ensure_claspc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'test fixture intentionally disables full GoalManager native compilation\n' >&2
exit 90
EOF
chmod +x "$fake_ensure_claspc"

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
codex_bin_json="$(json_string "$fake_codex")"
child_claspc_json="$(json_string "$fake_child_claspc")"
workspace_json="$(json_string "$workspace_root")"
project_root_json="$(json_string "$project_root")"
goal_json="$(json_string "Prove GoalManager can run the default planner backend without shell stdin shims.")"

mkdir -p "$workspace_root"
XDG_CACHE_HOME="$test_root_abs/xdg-cache" \
CLASP_LOOP_CODEX_BIN_JSON="$codex_bin_json" \
CLASP_MANAGER_CLASPC_BIN_JSON="$child_claspc_json" \
CLASP_MANAGER_PROJECT_ROOT_JSON="$project_root_json" \
CLASP_LOOP_WORKSPACE_JSON="$workspace_json" \
CLASP_MANAGER_GOAL_JSON="$goal_json" \
CLASP_MANAGER_OBJECTIVE_ID_JSON='"default-planner-command"' \
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
CLASP_TEST_PLANNER_LOG="$planner_log" \
CLASP_TEST_CHILD_LOG="$child_log" \
CLASP_TEST_STDIN_MARKER="$stdin_marker" \
CLASP_NATIVE_BUNDLE_JOBS="${CLASP_NATIVE_BUNDLE_JOBS:-1}" \
CLASP_NATIVE_IMAGE_SECTION_JOBS="${CLASP_NATIVE_IMAGE_SECTION_JOBS:-1}" \
CLASP_NATIVE_JOBS_MAX="${CLASP_NATIVE_JOBS_MAX:-1}" \
CLASP_NATIVE_RELAXED_BUILD_PLAN_CACHE="${CLASP_NATIVE_RELAXED_BUILD_PLAN_CACHE:-1}" \
timeout "$timeout_secs" "$goal_manager_bin" "$state_root" >"$output_path"

CLASP_MANAGER_COMMAND=status \
CLASP_NATIVE_BUNDLE_JOBS="${CLASP_NATIVE_BUNDLE_JOBS:-1}" \
CLASP_NATIVE_IMAGE_SECTION_JOBS="${CLASP_NATIVE_IMAGE_SECTION_JOBS:-1}" \
CLASP_NATIVE_JOBS_MAX="${CLASP_NATIVE_JOBS_MAX:-1}" \
CLASP_NATIVE_RELAXED_BUILD_PLAN_CACHE="${CLASP_NATIVE_RELAXED_BUILD_PLAN_CACHE:-1}" \
timeout "$timeout_secs" "$goal_manager_bin" "$state_root" >"$status_path"

node - "$output_path" "$status_path" "$planner_log" "$child_log" "$state_root" "$workspace_root" "$stdin_marker" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const [outputPath, statusPath, plannerLogPath, childLogPath, stateRoot, workspaceRoot, stdinMarker] =
  process.argv.slice(2);

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
const plannerInvocations = readJsonLines(plannerLogPath);
const childInvocations = readJsonLines(childLogPath);

assert(output.state?.phase === "completed", `manager output phase ${output.state?.phase}`);
assert(status.state?.phase === "completed", `manager status phase ${status.state?.phase}`);
assert(status.completedTaskIds.includes("default-planner-child"), "planned child task should complete");
assert(planner.tasks.length === 1 && planner.tasks[0].taskId === "default-planner-child", "planner report should come from fake default backend");
assert(plannerInvocations.length === 1, `expected one fake planner invocation, saw ${plannerInvocations.length}`);
assert(plannerInvocations[0].promptFromStdin === false, "planner prompt should not come from stdin");
assert(childInvocations.length === 1, `expected one child loop invocation, saw ${childInvocations.length}`);
assert(fs.readFileSync(path.join(workspaceRoot, ".clasp-task-workspaces", "default-planner-child", "workspace.txt"), "utf8").trim() === "default-planner-child-ok", "child workspace should be promoted");
assert(!fs.existsSync(stdinMarker), "default planner should not use stdin marker");
NODE

printf 'goal-manager-default-planner-command-ok\n'
