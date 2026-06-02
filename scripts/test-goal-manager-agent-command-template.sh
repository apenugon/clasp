#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_GOAL_MANAGER_AGENT_COMMAND_TEMPLATE_TIMEOUT_SECS:-300}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_GOAL_MANAGER_AGENT_COMMAND_TEMPLATE_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

export CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE="${CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE:-8}"

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
invalid_planner_state_root="$test_root_abs/invalid-planner-state"
invalid_planner_workspace_root="$test_root_abs/invalid-planner-workspace"
invalid_planner_output_path="$test_root_abs/invalid-planner-output.json"
invalid_planner_status_path="$test_root_abs/invalid-planner-status.json"
invalid_planner_agent_log="$test_root_abs/invalid-planner-agent-invocations.jsonl"
swarm_proof_report_path="${CLASP_GOAL_MANAGER_SWARM_PROOF_REPORT_JSON:-}"

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
if [[ "$prompt" != *"Planner agent backend: kind=template promptTransport=prompt-path valid=true"* ]]; then
  printf 'planner prompt missing backend summary\n' >&2
  exit 86
fi
if [[ "$prompt" != *"Planner agent backend policy repair:"* || "$prompt" != *"policyMessages="* || "$prompt" != *"policyRecommendedTemplate="* ]]; then
  printf 'planner prompt missing backend policy repair context\n' >&2
  exit 89
fi
if [[ "$prompt" != *"Planner agent backend capability repair:"* || "$prompt" != *"capabilityMessages="* || "$prompt" != *"capabilitySupports=planner:"* ]]; then
  printf 'planner prompt missing backend capability repair context\n' >&2
  exit 90
fi
if [[ "$prompt" != *"Planner context pack:"* || "$prompt" != *"task: planner-1"* ]]; then
  printf 'planner prompt missing native context pack\n' >&2
  exit 68
fi
if [[ "$prompt" != *"spawn policy: parent= depth=0/1 children=0/1 remaining-child-budget=1"* ]]; then
  printf 'planner prompt missing spawn budget context\n' >&2
  exit 87
fi
if [[ "$prompt" != *"child task ids:"* ]]; then
  printf 'planner prompt missing child task projection\n' >&2
  exit 88
fi
if [[ "$prompt" != *"artifact search matches:"* ]]; then
  printf 'planner prompt missing artifact search context\n' >&2
  exit 69
fi
if [[ "$prompt" != *"semantic index artifact matches:"* ]]; then
  printf 'planner prompt missing semantic index context\n' >&2
  exit 70
fi
if [[ "$prompt" != *"semantic index edit files:"* || "$prompt" != *"semantic index surface ids:"* ]]; then
  printf 'planner prompt missing semantic index projection context\n' >&2
  exit 84
fi
if [[ "$prompt" != *"dependency task ids:"* || "$prompt" != *"dependency task statuses:"* || "$prompt" != *"dependency task ready:"* ]]; then
  printf 'planner prompt missing dependency projection context\n' >&2
  exit 85
fi
if [[ "$prompt" != *"benchmark history matches:"* ]]; then
  printf 'planner prompt missing benchmark history context\n' >&2
  exit 83
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
task_text="$(cat "$task_file")"
task_route=""
task_content=""
if [[ "$task_text" == *"generic agent command templates"* ]]; then
  task_route="provider-neutral-child"
  task_content="provider-neutral-child-ok"
elif [[ "$task_text" == *"verify-affected"* || "$task_text" == *"compiler-slice"* ]]; then
  task_route="iteration-speed-loop"
  task_content="iteration-speed-child-ok"
elif [[ "$task_text" == *"semantic index projections"* || "$task_text" == *"standalone-agent routing"* ]]; then
  task_route="semantic-context-routing"
  task_content="semantic-context-child-ok"
elif [[ "$task_text" == *"standalone-swarm"* || "$task_text" == *"ordinary-Clasp swarm runtime"* ]]; then
  task_route="standalone-swarm-readiness"
  task_content="standalone-swarm-child-ok"
else
  printf 'child loop task prompt did not match a known local planner route\n' >&2
  exit 82
fi

mkdir -p "$workspace_root/notes" "$workspace_root/.clasp-test-tmp" "$state_root"
printf '%s\n' "$task_content" >"$workspace_root/workspace.txt"
printf '%s\n' "$task_content" >"$workspace_root/notes/child-artifact.txt"
printf '%s\n' "$task_route" >"$workspace_root/notes/local-planner-route.txt"
printf 'transient-noise\n' >"$workspace_root/.clasp-test-tmp/noise.txt"

printf '{"stateRoot":%s,"workspaceRoot":%s,"taskFile":%s,"taskRoute":%s,"agentCommandJson":%s,"agentBinJson":%s,"codexBinJson":%s,"agentMemoryMb":%s,"builderMemoryMb":%s,"verifierMemoryMb":%s}\n' \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$state_root")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$workspace_root")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$task_file")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$task_route")" \
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
node - "$state_root/feedback.json" "$task_route" <<'NODE'
const fs = require("node:fs");
const [feedbackPath, taskRoute] = process.argv.slice(2);
fs.writeFileSync(feedbackPath, `${JSON.stringify({
  verdict: "pass",
  summary: "generic child loop completed",
  findings: [],
  tests_run: ["generic child loop env", "goal-manager-local-planner-routed-child"],
  follow_up: [],
  capability_statuses: [{
    name: "provider_neutral_goal_manager",
    status: "pass",
    evidence: [
      "GoalManager passed CLASP_LOOP_AGENT_COMMAND_JSON to the child loop",
      `child loop executed local planner route: ${taskRoute}`,
    ],
    blocking_gaps: [],
    required_closure: [],
  }],
})}\n`);
NODE
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
node - \
  "$project_root/examples/swarm-native/GoalManagerAgentBackendConfig.clasp" \
  "$project_root/examples/swarm-native/GoalManagerConfig.clasp" \
  "$project_root/examples/swarm-native/GoalManagerBootstrapTasks.clasp" \
  "$project_root/examples/swarm-native/GoalManagerServiceMain.clasp" \
  "$project_root/examples/swarm-native/GoalManagerBootstrapPlanner.clasp" <<'NODE'
const fs = require("node:fs");
const [backendConfigPath, goalManagerConfigPath, bootstrapTasksPath, serviceMainPath, bootstrapPlannerPath] = process.argv.slice(2);
const backendConfig = fs.readFileSync(backendConfigPath, "utf8");
const goalManagerConfig = fs.readFileSync(goalManagerConfigPath, "utf8");
const bootstrapTasks = fs.readFileSync(bootstrapTasksPath, "utf8");
const serviceMain = fs.readFileSync(serviceMainPath, "utf8");
const bootstrapPlanner = fs.readFileSync(bootstrapPlannerPath, "utf8");

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function assertIncludes(source, needle, message) {
  assert(source.includes(needle), message || `missing ${needle}`);
}

function assertNotIncludes(source, needle, message) {
  assert(!source.includes(needle), message || `unexpected ${needle}`);
}

assertIncludes(goalManagerConfig, "import GoalManagerAgentBackendConfig", "GoalManagerConfig should import standalone backend config");
assertNotIncludes(goalManagerConfig, "import AgentBackend", "GoalManagerConfig should not pull AgentBackend directly");
assertIncludes(backendConfig, "CLASP_REQUIRE_STANDALONE_AGENT_BACKEND_JSON", "global standalone flag should be true");
assertIncludes(backendConfig, "CLASP_LOOP_REQUIRE_STANDALONE_AGENT_BACKEND_JSON", "loop standalone should inherit the global flag");
assertIncludes(backendConfig, "CLASP_MANAGER_REQUIRE_STANDALONE_PLANNER_AGENT_BACKEND_JSON", "planner standalone flag should be true");
assertIncludes(backendConfig, "anyStandaloneAgentBackendRequired : Bool", "standalone aggregate flag should be true");
assertIncludes(backendConfig, "if anyStandaloneAgentBackendRequired then\n    managerClaspcBin", "planner standalone should trigger local agent bin fallback");
assertIncludes(backendConfig, "agentBackendLocalAgentTemplate", "standalone agent template should use the local Clasp agent");
assertIncludes(backendConfig, "agentBackendLocalPlannerTemplate", "standalone planner template should use the local Clasp planner");
assertIncludes(backendConfig, "agentCapabilityProfileFallback : Str", "standalone child agents should default to local-clasp profile");
assertIncludes(backendConfig, "plannerAgentCapabilityProfileFallback : Str", "standalone planner should default to local-clasp profile");
assertIncludes(backendConfig, "agentBackendConfigReadEnvTextList \"CLASP_LOOP_AGENT_COMMAND_JSON\" agentCommandTemplateFallback", "explicit agent template should override standalone default");
assertIncludes(backendConfig, "agentBackendConfigReadEnvTextList \"CLASP_MANAGER_PLANNER_AGENT_COMMAND_JSON\" plannerAgentCommandTemplateFallback", "explicit planner template should override standalone default");
assertIncludes(goalManagerConfig, "childAffectedVerificationPlanJson", "GoalManager should read affected verification plan JSON for child loops");
assertIncludes(goalManagerConfig, "childAffectedVerificationLaunchPolicyJson", "GoalManager should read affected verification launch policy JSON for child loops");
assertIncludes(bootstrapTasks, "CLASP_LOOP_AFFECTED_VERIFICATION_PLAN_JSON=", "child loop command should pass affected verification plan JSON");
assertIncludes(bootstrapTasks, "CLASP_LOOP_AFFECTED_VERIFICATION_PLAN_PATH_JSON=", "child loop command should pass affected verification plan path");
assertIncludes(bootstrapTasks, "CLASP_LOOP_AFFECTED_VERIFICATION_LAUNCH_POLICY_JSON=", "child loop command should pass affected verification launch policy JSON");
assertIncludes(bootstrapTasks, "CLASP_LOOP_AFFECTED_VERIFICATION_LAUNCH_POLICY_PATH_JSON=", "child loop command should pass affected verification launch policy path");
assertIncludes(serviceMain, "CLASP_LOOP_AFFECTED_VERIFICATION_PLAN_JSON=", "service restart should preserve affected verification plan JSON");
assertIncludes(serviceMain, "CLASP_LOOP_AFFECTED_VERIFICATION_PLAN_PATH_JSON=", "service restart should preserve affected verification plan path");
assertIncludes(serviceMain, "CLASP_LOOP_AFFECTED_VERIFICATION_LAUNCH_POLICY_JSON=", "service restart should preserve affected verification launch policy JSON");
assertIncludes(serviceMain, "CLASP_LOOP_AFFECTED_VERIFICATION_LAUNCH_POLICY_PATH_JSON=", "service restart should preserve affected verification launch policy path");
assertIncludes(bootstrapPlanner, "plannerAffectedVerificationContextSection", "planner prompt should include affected verification context");
assertIncludes(bootstrapPlanner, "Affected verification launch policy JSON:", "planner prompt should expose affected verification launch policy block");
assertIncludes(bootstrapPlanner, "Affected verification plan path:", "planner prompt should expose affected verification plan path block");
assertIncludes(bootstrapPlanner, "Affected verification launch policy path:", "planner prompt should expose affected verification launch policy path block");
assertIncludes(bootstrapPlanner, "childAffectedVerificationPlanInlineJson", "planner prompt should only inline explicitly inline affected verification plan JSON");
assertIncludes(bootstrapPlanner, "childAffectedVerificationLaunchPolicyInlineJson", "planner prompt should only inline explicitly inline affected verification launch policy JSON");
NODE
goal_manager_bin="$(
  XDG_CACHE_HOME="$test_root_abs/xdg-cache" \
  CLASP_GOAL_MANAGER_CLASPC_BIN="$fake_ensure_claspc" \
  CLASP_GOAL_MANAGER_COMPILE_MANAGED="${CLASP_GOAL_MANAGER_COMPILE_MANAGED:-0}" \
  CLASP_GOAL_MANAGER_COMPILE_TIMEOUT_SECS="${CLASP_GOAL_MANAGER_COMPILE_TIMEOUT_SECS:-1}" \
  CLASP_GOAL_MANAGER_COMPILE_ATTEMPTS="${CLASP_GOAL_MANAGER_COMPILE_ATTEMPTS:-1}" \
  CLASP_GOAL_MANAGER_ALLOW_STALE_ON_COMPILE_FAILURE="${CLASP_GOAL_MANAGER_ALLOW_STALE_ON_COMPILE_FAILURE:-1}" \
  CLASP_GOAL_MANAGER_ALLOW_UNMANAGED_STALE="${CLASP_GOAL_MANAGER_ALLOW_UNMANAGED_STALE:-1}" \
  CLASP_GOAL_MANAGER_COMPILE_MEMORY_MB="${CLASP_GOAL_MANAGER_COMPILE_MEMORY_MB:-8192}" \
  CLASP_GOAL_MANAGER_COMPILE_MIN_AVAILABLE_MEMORY_MB="${CLASP_GOAL_MANAGER_COMPILE_MIN_AVAILABLE_MEMORY_MB:-45056}" \
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

invalid_planner_command_json="$(
  node - <<'NODE'
process.stdout.write(JSON.stringify([
  "{agent_bin}",
  "--role",
  "{role}"
]));
NODE
)"

grep -F 'clasp-local-planner' "$project_root/examples/swarm-native/LocalPlanner.clasp" >/dev/null
local_planner_bin="$test_root_abs/local-planner-bin"
env RUSTC=/definitely-missing-rustc CLASP_PROJECT_ROOT="$project_root" \
  timeout "$timeout_secs" "$claspc_bin" compile "$project_root/examples/swarm-native/LocalPlanner.clasp" \
    -o "$local_planner_bin" >/dev/null
planner_agent_command_json="$(
  node - "$local_planner_bin" <<'NODE'
const localPlannerBin = process.argv[2];
process.stdout.write(JSON.stringify([
  localPlannerBin,
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

local_planner_direct_prompt="$test_root_abs/local-planner-speed.prompt.txt"
local_planner_direct_report="$test_root_abs/local-planner-speed-report.json"
local_planner_direct_workspace="$test_root_abs/local-planner-speed-workspace"
local_planner_direct_log="$test_root_abs/local-planner-speed-invocations.jsonl"
local_planner_direct_output="$test_root_abs/local-planner-speed-output.txt"
local_planner_context_prompt="$test_root_abs/local-planner-context.prompt.txt"
local_planner_context_report="$test_root_abs/local-planner-context-report.json"
local_planner_context_workspace="$test_root_abs/local-planner-context-workspace"
local_planner_context_log="$test_root_abs/local-planner-context-invocations.jsonl"
local_planner_context_output="$test_root_abs/local-planner-context-output.txt"
local_planner_standalone_prompt="$test_root_abs/local-planner-standalone.prompt.txt"
local_planner_standalone_report="$test_root_abs/local-planner-standalone-report.json"
local_planner_standalone_workspace="$test_root_abs/local-planner-standalone-workspace"
local_planner_standalone_log="$test_root_abs/local-planner-standalone-invocations.jsonl"
local_planner_standalone_output="$test_root_abs/local-planner-standalone-output.txt"
local_planner_goal_prompt="$test_root_abs/local-planner-ai-agent-swarm-goal.prompt.txt"
local_planner_goal_report="$test_root_abs/local-planner-ai-agent-swarm-goal-report.json"
local_planner_goal_workspace="$test_root_abs/local-planner-ai-agent-swarm-goal-workspace"
local_planner_goal_log="$test_root_abs/local-planner-ai-agent-swarm-goal-invocations.jsonl"
local_planner_goal_output="$test_root_abs/local-planner-ai-agent-swarm-goal-output.txt"
local_planner_audit_prompt="$test_root_abs/local-planner-capability-audit.prompt.txt"
local_planner_audit_report="$test_root_abs/local-planner-capability-audit-report.json"
local_planner_audit_workspace="$test_root_abs/local-planner-capability-audit-workspace"
local_planner_audit_log="$test_root_abs/local-planner-capability-audit-invocations.jsonl"
local_planner_audit_output="$test_root_abs/local-planner-capability-audit-output.txt"
local_planner_catalog_prompt="$test_root_abs/local-planner-catalog.prompt.txt"
local_planner_catalog_report="$test_root_abs/local-planner-catalog-report.json"
local_planner_catalog_workspace="$test_root_abs/local-planner-catalog-workspace"
local_planner_catalog_log="$test_root_abs/local-planner-catalog-invocations.jsonl"
local_planner_catalog_output="$test_root_abs/local-planner-catalog-output.txt"
local_planner_workspace_catalog_prompt="$test_root_abs/local-planner-workspace-catalog.prompt.txt"
local_planner_workspace_catalog_report="$test_root_abs/local-planner-workspace-catalog-report.json"
local_planner_workspace_catalog_workspace="$test_root_abs/local-planner-workspace-catalog-workspace"
local_planner_workspace_catalog_path="$local_planner_workspace_catalog_workspace/.clasp-local-planner/task-catalog.json"
local_planner_workspace_catalog_log="$test_root_abs/local-planner-workspace-catalog-invocations.jsonl"
local_planner_workspace_catalog_output="$test_root_abs/local-planner-workspace-catalog-output.txt"
planner_fingerprint_workspace="$test_root_abs/planner-fingerprint-workspace"
planner_fingerprint_catalog_path="$planner_fingerprint_workspace/.clasp-local-planner/task-catalog.json"
planner_fingerprint_memory_path="$planner_fingerprint_workspace/planner-memory-2.md"
planner_fingerprint_backlog_path="$planner_fingerprint_workspace/planner-backlog-2.md"
planner_fingerprint_mailbox_path="$planner_fingerprint_workspace/mailbox.json"
planner_fingerprint_a="$test_root_abs/planner-fingerprint-a.json"
planner_fingerprint_b="$test_root_abs/planner-fingerprint-b.json"
cat >"$local_planner_direct_prompt" <<'EOF'
You are the planner subagent for the Clasp repository.
Plan the next bounded tasks needed to improve Clasp autonomously.

High-level goal:
Improve iteration speed and semantic context for compiler self-improvement.

Planner agent backend policy repair:
policyMessages=none
policyMissingPlaceholders=none
policyRecommendedTemplate={agent_bin} | --role | {role} | --schema | {schema_path} | --report | {report_path} | --prompt-path | {prompt_path} | --workspace | {workspace_root}

Planner context pack:
task: planner-1 status=ready ready=true attempts=0
dependency task ids:
- none
dependency task statuses:
- none
dependency task ready:
- none
artifact search matches:
- none
semantic index artifact matches:
- none
semantic index edit files:
- src/Compiler/Checker.clasp
semantic index surface ids:
- compiler:checker
benchmark history matches:
- none

Plan 1-3 bounded tasks with explicit dependencies and task prompts.
EOF

timeout "$timeout_secs" "$local_planner_bin" \
  --role planner \
  --schema "$project_root/agents/schemas/planner-report.schema.json" \
  --report "$local_planner_direct_report" \
  --prompt-path "$local_planner_direct_prompt" \
  --workspace "$local_planner_direct_workspace" \
  --log "$local_planner_direct_log" \
  >"$local_planner_direct_output"

node - "$local_planner_direct_report" "$local_planner_direct_log" "$local_planner_direct_workspace" <<'NODE'
const fs = require("node:fs");
const [reportPath, logPath, workspaceRoot] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const logEntries = fs.readFileSync(logPath, "utf8").trim().split(/\n/).filter(Boolean).map((line) => JSON.parse(line));

assert(report.objectiveSummary.includes("iteration-speed"), `objective summary ${report.objectiveSummary}`);
assert(report.tasks.length === 3, `task count ${report.tasks.length}`);
assert(report.tasks[0].taskId === "iteration-speed-loop", `task id ${report.tasks[0].taskId}`);
assert(report.tasks[0].role === "compiler-speed-worker", `task role ${report.tasks[0].role}`);
assert(report.tasks[0].taskPrompt.includes("verify-affected"), "iteration-speed task should steer focused verification");
assert(report.tasks[0].coordinationFocus.includes("iteration-speed"), "coordination focus should include iteration-speed");
assert(report.tasks[0].coordinationFocus.includes("compiler-checker"), "coordination focus should include compiler-checker");
assert(report.tasks[1].taskId === "semantic-context-routing", `task id ${report.tasks[1].taskId}`);
assert(report.tasks[1].coordinationFocus.includes("semantic-index"), "second task should route semantic-index work");
assert(report.tasks[2].taskId === "standalone-swarm-readiness", `task id ${report.tasks[2].taskId}`);
assert(report.tasks[2].coordinationFocus.includes("standalone-swarm"), "third task should route standalone-swarm work");
assert(report.tasks[2].dependencies?.join(",") === "iteration-speed-loop,semantic-context-routing", `third task dependencies ${report.tasks[2].dependencies}`);
assert(report.testsRun.includes("clasp-local-planner-heuristic-routing"), "planner should record heuristic routing coverage");
assert(report.testsRun.includes("clasp-local-planner-backend-policy-repair"), "planner should record backend policy repair coverage");
assert(logEntries.length === 1, `log entries ${logEntries.length}`);
assert(logEntries[0].backend === "clasp-local-planner", `backend ${logEntries[0].backend}`);
assert(logEntries[0].workspaceRoot === workspaceRoot, `workspace root ${logEntries[0].workspaceRoot}`);
assert(fs.existsSync(workspaceRoot), "planner should create the workspace root");
NODE

cat >"$local_planner_context_prompt" <<'EOF'
You are the planner subagent for the Clasp repository.
Plan the next bounded tasks needed to improve Clasp autonomously.

High-level goal:
Choose the next bounded task from the supplied native evidence.

Planner context pack:
task: planner-1 status=ready ready=true attempts=0
dependency task ids:
- none
dependency task statuses:
- none
dependency task ready:
- none
artifact search matches:
- none
semantic index artifact matches:
- none
semantic index edit files:
examples/swarm-native/Swarm.clasp
semantic index surface ids:
swarm:context-pack
benchmark history matches:
- none

Plan 1-2 bounded tasks with explicit dependencies and task prompts.
EOF

timeout "$timeout_secs" "$local_planner_bin" \
  --role planner \
  --schema "$project_root/agents/schemas/planner-report.schema.json" \
  --report "$local_planner_context_report" \
  --prompt-path "$local_planner_context_prompt" \
  --workspace "$local_planner_context_workspace" \
  --log "$local_planner_context_log" \
  >"$local_planner_context_output"

node - "$local_planner_context_report" "$local_planner_context_log" <<'NODE'
const fs = require("node:fs");
const [reportPath, logPath] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const logEntries = fs.readFileSync(logPath, "utf8").trim().split(/\n/).filter(Boolean).map((line) => JSON.parse(line));

assert(report.tasks.length === 2, `context task count ${report.tasks.length}`);
assert(report.tasks[0].taskId === "semantic-context-routing", `context task id ${report.tasks[0].taskId}`);
assert(report.tasks[0].coordinationFocus.includes("semantic-index"), "context evidence should route semantic-index work");
assert(report.tasks[1].taskId === "standalone-swarm-readiness", `context second task id ${report.tasks[1].taskId}`);
assert(report.tasks[1].dependencies?.join(",") === "semantic-context-routing", `context dependencies ${report.tasks[1].dependencies}`);
assert(logEntries.length === 1, `context log entries ${logEntries.length}`);
NODE

cat >"$local_planner_standalone_prompt" <<'EOF'
You are the planner subagent for the Clasp repository.
Plan the next bounded tasks needed to improve Clasp autonomously.

High-level goal:
Improve standalone swarm readiness with one ordinary Clasp runtime task.

Planner context pack:
task: planner-1 status=ready ready=true attempts=0
dependency task ids:
- none
dependency task statuses:
- none
dependency task ready:
- none
artifact search matches:
- none
semantic index artifact matches:
- none
semantic index edit files:
- none
semantic index surface ids:
- none
benchmark history matches:
- none

Plan 1-1 bounded tasks with explicit dependencies and task prompts.
EOF

timeout "$timeout_secs" "$local_planner_bin" \
  --role planner \
  --schema "$project_root/agents/schemas/planner-report.schema.json" \
  --report "$local_planner_standalone_report" \
  --prompt-path "$local_planner_standalone_prompt" \
  --workspace "$local_planner_standalone_workspace" \
  --log "$local_planner_standalone_log" \
  >"$local_planner_standalone_output"

node - "$local_planner_standalone_report" "$local_planner_standalone_log" <<'NODE'
const fs = require("node:fs");
const [reportPath, logPath] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const logEntries = fs.readFileSync(logPath, "utf8").trim().split(/\n/).filter(Boolean).map((line) => JSON.parse(line));

assert(report.tasks.length === 1, `standalone task count ${report.tasks.length}`);
assert(report.tasks[0].taskId === "standalone-swarm-readiness", `standalone task id ${report.tasks[0].taskId}`);
assert(report.tasks[0].dependencies?.length === 0, "single standalone task should have no dependencies");
assert(report.tasks[0].coordinationFocus.includes("standalone-swarm"), "empty context labels should not force semantic routing");
assert(report.tasks[0].coordinationFocus.includes("direct-source-edit"), "standalone planner task should request direct source edit proof");
assert(report.tasks[0].coordinationFocus.includes("multi-file-source-edit"), "standalone planner task should request multi-file source edit proof");
assert(report.tasks[0].coordinationFocus.includes("source-patch-plan"), "standalone planner task should request source patch plan proof");
assert(report.tasks[0].coordinationFocus.includes("multi-surface-source-patch"), "standalone planner task should request multi-surface source patch proof");
assert(report.tasks[0].coordinationFocus.includes("repo-scale-source-patch"), "standalone planner task should request repo-scale source patch proof");
assert(report.tasks[0].taskPrompt.includes("direct source edit"), "standalone planner task prompt should request direct source edits");
assert(report.tasks[0].taskPrompt.includes("multi-surface"), "standalone planner task prompt should request multi-surface edits");
assert(report.tasks[0].taskPrompt.includes("repo-scale"), "standalone planner task prompt should request repo-scale edits");
assert(report.tasks[0].taskPrompt.includes("scripts/standalone-swarm-verify.sh --closure --json"), "standalone planner task prompt should name JSON closure verifier");
assert(report.tasks[0].taskPrompt.includes("Source edit plan:"), "standalone planner task prompt should include source edit plan");
assert(report.tasks[0].taskPrompt.includes("Source edit patches:"), "standalone planner task prompt should include source patch plan");
assert(report.tasks[0].taskPrompt.includes("src/StandaloneSwarmReadiness.clasp"), "standalone planner task prompt should name readiness source file");
assert(report.tasks[0].taskPrompt.includes("src/StandaloneSwarmVerifier.clasp"), "standalone planner task prompt should name verifier source file");
assert(report.tasks[0].taskPrompt.includes("examples/swarm-native/StandaloneSwarmHarness.clasp"), "standalone planner task prompt should name harness source file");
assert(report.tasks[0].taskPrompt.includes("examples/swarm-native/StandaloneSwarmRouting.clasp"), "standalone planner task prompt should name routing source file");
assert(report.tasks[0].taskPrompt.includes("scripts/standalone-swarm-readiness.sh"), "standalone planner task prompt should name script source file");
assert(report.tasks[0].taskPrompt.includes("scripts/standalone-swarm-verify.sh"), "standalone planner task prompt should name verifier script source file");
assert(report.tasks[0].taskPrompt.includes("docs/standalone-swarm-readiness.md"), "standalone planner task prompt should name doc source file");
assert(report.tasks[0].taskPrompt.includes("runtime/standalone_swarm_probe.rs"), "standalone planner task prompt should name runtime source file");
assert(report.tasks[0].taskPrompt.includes('readinessStatus = "open" => readinessStatus = "standalone-swarm-fixed-after-feedback"'), "standalone planner task prompt should include readiness patch");
assert(report.tasks[0].taskPrompt.includes('verifierStatus = "open" => verifierStatus = "standalone-swarm-fixed-after-feedback"'), "standalone planner task prompt should include verifier patch");
assert(report.tasks[0].taskPrompt.includes('harnessStatus = "open" => harnessStatus = "standalone-swarm-fixed-after-feedback"'), "standalone planner task prompt should include harness patch");
assert(report.tasks[0].taskPrompt.includes('routingStatus = "open" => routingStatus = "standalone-swarm-fixed-after-feedback"'), "standalone planner task prompt should include routing patch");
assert(report.tasks[0].taskPrompt.includes('echo "standalone-swarm=open" => echo "standalone-swarm=standalone-swarm-fixed-after-feedback"'), "standalone planner task prompt should include script patch");
assert(report.tasks[0].taskPrompt.includes('echo "standalone-swarm-verifier=open" => echo "standalone-swarm-verifier=standalone-swarm-fixed-after-feedback"'), "standalone planner task prompt should include verifier script patch");
assert(report.tasks[0].taskPrompt.includes("standalone-swarm-status: open => standalone-swarm-status: standalone-swarm-fixed-after-feedback"), "standalone planner task prompt should include doc patch");
assert(report.tasks[0].taskPrompt.includes('STANDALONE_SWARM_STATUS: &str = "open"'), "standalone planner task prompt should include runtime patch");
assert(logEntries.length === 1, `standalone log entries ${logEntries.length}`);
NODE

cat >"$local_planner_catalog_prompt" <<'EOF'
You are the planner subagent for the Clasp repository.
Plan the next bounded tasks needed to improve Clasp autonomously.

High-level goal:
Improve standalone-swarm readiness with a configured ordinary Clasp planner catalog.

Planner context pack:
task: planner-1 status=ready ready=true attempts=0
dependency task ids:
- none
dependency task statuses:
- none
dependency task ready:
- none
artifact search matches:
- none
semantic index artifact matches:
- none
semantic index edit files:
- none
semantic index surface ids:
- none
benchmark history matches:
- none

Plan 1-1 bounded tasks with explicit dependencies and task prompts.
EOF

local_planner_catalog_json="$(
  node - <<'NODE'
process.stdout.write(JSON.stringify([
  {
    route: "standalone-swarm",
    objectiveSummary: "Use a configured ordinary-Clasp planner catalog.",
    strategy: "Select runtime-editable planner behavior without changing the compiler or local planner source.",
    tasks: [
      {
        taskId: "catalog-runtime-gap",
        role: "catalog-worker",
        detail: "Verify planner behavior can be changed through a typed task catalog.",
        dependencies: [],
        taskPrompt: "Use the configured local planner task catalog to close one standalone swarm runtime gap.",
        coordinationFocus: ["catalog", "ordinary-clasp-program", "self-improving-planner"]
      },
      {
        taskId: "catalog-extra-task",
        role: "catalog-worker",
        detail: "This task proves the prompt task-budget contract still bounds configured catalogs.",
        dependencies: ["catalog-runtime-gap"],
        taskPrompt: "This task should be omitted when the planner budget is one.",
        coordinationFocus: ["catalog-budget"]
      }
    ],
    testsRun: ["clasp-local-planner-task-catalog"],
    residualRisks: ["catalog coverage is fixture-scoped"]
  }
]));
NODE
)"

CLASP_LOCAL_PLANNER_TASK_CATALOG_JSON="$local_planner_catalog_json" \
timeout "$timeout_secs" "$local_planner_bin" \
  --role planner \
  --schema "$project_root/agents/schemas/planner-report.schema.json" \
  --report "$local_planner_catalog_report" \
  --prompt-path "$local_planner_catalog_prompt" \
  --workspace "$local_planner_catalog_workspace" \
  --log "$local_planner_catalog_log" \
  >"$local_planner_catalog_output"

node - "$local_planner_catalog_report" "$local_planner_catalog_log" "$local_planner_catalog_workspace" <<'NODE'
const fs = require("node:fs");
const [reportPath, logPath, workspaceRoot] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const logEntries = fs.readFileSync(logPath, "utf8").trim().split(/\n/).filter(Boolean).map((line) => JSON.parse(line));

assert(report.objectiveSummary === "Use a configured ordinary-Clasp planner catalog.", `catalog objective ${report.objectiveSummary}`);
assert(report.strategy.includes("runtime-editable planner behavior"), `catalog strategy ${report.strategy}`);
assert(report.tasks.length === 1, `catalog task count ${report.tasks.length}`);
assert(report.tasks[0].taskId === "catalog-runtime-gap", `catalog task id ${report.tasks[0].taskId}`);
assert(report.tasks[0].role === "catalog-worker", `catalog task role ${report.tasks[0].role}`);
assert(report.tasks[0].dependencies?.length === 0, "catalog first task should keep empty dependencies");
assert(report.tasks[0].taskPrompt.includes("configured local planner task catalog"), "catalog task prompt should come from config");
assert(report.tasks[0].coordinationFocus.includes("self-improving-planner"), "catalog task should carry configured focus");
assert(!report.tasks.some((task) => task.taskId === "catalog-extra-task"), "task budget should bound configured catalogs");
assert(report.testsRun.includes("clasp-local-planner-template"), "catalog plan should keep default planner coverage");
assert(report.testsRun.includes("clasp-local-planner-task-catalog"), "catalog plan should record task-catalog coverage");
assert(report.residualRisks.includes("catalog coverage is fixture-scoped"), "catalog residual risks should be carried through");
assert(logEntries.length === 1, `catalog log entries ${logEntries.length}`);
assert(logEntries[0].backend === "clasp-local-planner", `catalog backend ${logEntries[0].backend}`);
assert(logEntries[0].workspaceRoot === workspaceRoot, `catalog workspace root ${logEntries[0].workspaceRoot}`);
NODE

cat >"$local_planner_workspace_catalog_prompt" <<'EOF'
You are the planner subagent for the Clasp repository.
Plan the next bounded tasks needed to improve Clasp autonomously.

High-level goal:
Improve standalone-swarm readiness using a workspace-local ordinary Clasp planner catalog.

Planner context pack:
task: planner-1 status=ready ready=true attempts=0
dependency task ids:
- none
dependency task statuses:
- none
dependency task ready:
- none
artifact search matches:
- none
semantic index artifact matches:
- none
semantic index edit files:
- none
semantic index surface ids:
- none
benchmark history matches:
- none

Plan 1-1 bounded tasks with explicit dependencies and task prompts.
EOF

mkdir -p "$(dirname "$local_planner_workspace_catalog_path")"
node - "$local_planner_workspace_catalog_path" <<'NODE'
const fs = require("node:fs");
const [catalogPath] = process.argv.slice(2);

fs.writeFileSync(catalogPath, JSON.stringify([
  {
    route: "standalone-swarm",
    objectiveSummary: "Use a workspace-local ordinary-Clasp planner catalog.",
    strategy: "Load planner behavior from a workspace artifact that an ordinary Clasp loop can rewrite between planning waves.",
    tasks: [
      {
        taskId: "workspace-catalog-runtime-gap",
        role: "workspace-catalog-worker",
        detail: "Verify workspace-local planner catalogs can steer standalone swarm planning.",
        dependencies: [],
        taskPrompt: "Use the workspace-local local planner task catalog to close one standalone swarm runtime gap.",
        coordinationFocus: ["workspace-catalog", "ordinary-clasp-program", "self-improving-planner"]
      },
      {
        taskId: "workspace-catalog-extra-task",
        role: "workspace-catalog-worker",
        detail: "This task proves the prompt task-budget contract still bounds workspace catalogs.",
        dependencies: ["workspace-catalog-runtime-gap"],
        taskPrompt: "This task should be omitted when the planner budget is one.",
        coordinationFocus: ["workspace-catalog-budget"]
      }
    ],
    testsRun: ["clasp-local-planner-workspace-task-catalog"],
    residualRisks: ["workspace catalog coverage is fixture-scoped"]
  }
]));
NODE

timeout "$timeout_secs" "$local_planner_bin" \
  --role planner \
  --schema "$project_root/agents/schemas/planner-report.schema.json" \
  --report "$local_planner_workspace_catalog_report" \
  --prompt-path "$local_planner_workspace_catalog_prompt" \
  --workspace "$local_planner_workspace_catalog_workspace" \
  --log "$local_planner_workspace_catalog_log" \
  >"$local_planner_workspace_catalog_output"

node - "$local_planner_workspace_catalog_report" "$local_planner_workspace_catalog_log" "$local_planner_workspace_catalog_workspace" <<'NODE'
const fs = require("node:fs");
const [reportPath, logPath, workspaceRoot] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const logEntries = fs.readFileSync(logPath, "utf8").trim().split(/\n/).filter(Boolean).map((line) => JSON.parse(line));

assert(report.objectiveSummary === "Use a workspace-local ordinary-Clasp planner catalog.", `workspace catalog objective ${report.objectiveSummary}`);
assert(report.strategy.includes("workspace artifact"), `workspace catalog strategy ${report.strategy}`);
assert(report.tasks.length === 1, `workspace catalog task count ${report.tasks.length}`);
assert(report.tasks[0].taskId === "workspace-catalog-runtime-gap", `workspace catalog task id ${report.tasks[0].taskId}`);
assert(report.tasks[0].role === "workspace-catalog-worker", `workspace catalog task role ${report.tasks[0].role}`);
assert(report.tasks[0].dependencies?.length === 0, "workspace catalog first task should keep empty dependencies");
assert(report.tasks[0].taskPrompt.includes("workspace-local local planner task catalog"), "workspace catalog task prompt should come from config");
assert(report.tasks[0].coordinationFocus.includes("self-improving-planner"), "workspace catalog task should carry configured focus");
assert(!report.tasks.some((task) => task.taskId === "workspace-catalog-extra-task"), "task budget should bound workspace catalogs");
assert(report.testsRun.includes("clasp-local-planner-template"), "workspace catalog plan should keep default planner coverage");
assert(report.testsRun.includes("clasp-local-planner-workspace-task-catalog"), "workspace catalog plan should record workspace catalog coverage");
assert(report.residualRisks.includes("workspace catalog coverage is fixture-scoped"), "workspace catalog residual risks should be carried through");
assert(logEntries.length === 1, `workspace catalog log entries ${logEntries.length}`);
assert(logEntries[0].backend === "clasp-local-planner", `workspace catalog backend ${logEntries[0].backend}`);
assert(logEntries[0].workspaceRoot === workspaceRoot, `workspace catalog workspace root ${logEntries[0].workspaceRoot}`);
NODE

mkdir -p "$(dirname "$planner_fingerprint_catalog_path")"
cat >"$planner_fingerprint_memory_path" <<'EOF'
planner memory harness line
EOF
cat >"$planner_fingerprint_backlog_path" <<'EOF'
planner backlog harness line
EOF
node - "$planner_fingerprint_mailbox_path" <<'NODE'
const fs = require("node:fs");
const [mailboxPath] = process.argv.slice(2);
fs.writeFileSync(mailboxPath, JSON.stringify([
  {
    source: "planner-input-harness",
    taskId: "mailbox-task",
    wave: 1,
    summary: "mailbox summary harness line",
    details: ["capability-evidence=local_verifier_gate:harness mailbox evidence"]
  }
]));
NODE
node - "$planner_fingerprint_catalog_path" <<'NODE'
const fs = require("node:fs");
const [catalogPath] = process.argv.slice(2);
fs.writeFileSync(catalogPath, JSON.stringify([
  {
    route: "standalone-swarm",
    objectiveSummary: "Fingerprint catalog A.",
    strategy: "Catalog A should affect planner input reuse.",
    tasks: [],
    testsRun: ["catalog-a"],
    residualRisks: []
  }
]));
NODE

write_planner_fingerprint_source() {
  local output_path="$1"
  CLASP_MANAGER_WORKSPACE_ROOT_JSON="$(json_string "$planner_fingerprint_workspace")" \
  CLASP_MANAGER_PROJECT_ROOT_JSON="$(json_string "$project_root")" \
  CLASP_MANAGER_GOAL_JSON="$(json_string "Harness planner input fingerprints should include reusable standalone swarm evidence.")" \
  CLASP_MANAGER_PLANNER_POLICY_JSON="$(json_string "Harness planner policy")" \
  node - \
    "$planner_fingerprint_workspace" \
    "$planner_fingerprint_catalog_path" \
    "$planner_fingerprint_memory_path" \
    "$planner_fingerprint_backlog_path" \
    "$planner_fingerprint_mailbox_path" \
    >"$output_path" <<'NODE'
const crypto = require("node:crypto");
const fs = require("node:fs");
const [workspaceRoot, catalogPath, memoryPath, backlogPath, mailboxPath] = process.argv.slice(2);

function jsonEnv(name, fallback) {
  const raw = process.env[name];
  return raw ? JSON.parse(raw) : fallback;
}

function textOr(path, fallback) {
  if (!fs.existsSync(path)) return fallback;
  const raw = fs.readFileSync(path, "utf8");
  return raw === "" ? fallback : raw;
}

function fingerprintText(raw) {
  return crypto.createHash("sha256").update(raw).digest("hex");
}

function catalogFileFingerprint(path) {
  if (!path) return "missing";
  if (!fs.existsSync(path)) return `${path}:missing`;
  return `${path}:${fingerprintText(fs.readFileSync(path, "utf8"))}`;
}

function mailboxSummary() {
  if (!fs.existsSync(mailboxPath)) return "No prior swarm mailbox messages are available yet.";
  const messages = JSON.parse(fs.readFileSync(mailboxPath, "utf8"));
  if (!messages.length) return "No prior swarm mailbox messages are available yet.";
  const rendered = [];
  for (const message of messages) {
    const task = message.taskId ? ` ${message.taskId}` : "";
    rendered.push(`[${message.source}${task} wave ${message.wave}] ${message.summary}`);
    for (const detail of message.details || []) {
      if (detail) rendered.push(`  - ${detail}`);
    }
  }
  return rendered.join("\n");
}

const goal = jsonEnv("CLASP_MANAGER_GOAL_JSON", "Improve Clasp by planning bounded native compiler/runtime/language tasks and closing them with ordinary Clasp loops.");
const plannerPolicy = jsonEnv("CLASP_MANAGER_PLANNER_POLICY_JSON", "");
const projectRoot = jsonEnv("CLASP_MANAGER_PROJECT_ROOT_JSON", process.cwd());
const resolvedWorkspaceRoot = jsonEnv("CLASP_MANAGER_WORKSPACE_ROOT_JSON", workspaceRoot);
const catalogSource = [
  "env-json:missing",
  "env-path:missing",
  `workspace-path:${catalogFileFingerprint(catalogPath)}`
].join("\n");

process.stdout.write([
  `goal:${goal}`,
  `planner-policy:${plannerPolicy}`,
  "schema-path:",
  `project-root:${projectRoot}`,
  `workspace-root:${resolvedWorkspaceRoot}`,
  "wave:2",
  "benchmark-enabled:false",
  "benchmark-summary:benchmark-summary-harness",
  `planner-memory:${textOr(memoryPath, "No prior wave memory is available yet.")}`,
  `planner-backlog:${textOr(backlogPath, "No prioritized backlog is available yet.")}`,
  `planner-task-catalog:${catalogSource}`,
  `mailbox-summary:${mailboxSummary()}`
].join("\n"));
NODE
}

write_planner_fingerprint_source "$planner_fingerprint_a"

node - "$planner_fingerprint_catalog_path" <<'NODE'
const fs = require("node:fs");
const [catalogPath] = process.argv.slice(2);
fs.writeFileSync(catalogPath, JSON.stringify([
  {
    route: "standalone-swarm",
    objectiveSummary: "Fingerprint catalog B.",
    strategy: "Catalog B should invalidate a planner report reused from catalog A.",
    tasks: [],
    testsRun: ["catalog-b"],
    residualRisks: []
  }
]));
NODE

write_planner_fingerprint_source "$planner_fingerprint_b"

node - "$planner_fingerprint_a" "$planner_fingerprint_b" "$planner_fingerprint_workspace" <<'NODE'
const fs = require("node:fs");
const [firstPath, secondPath, workspaceRoot] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const first = fs.readFileSync(firstPath, "utf8");
const second = fs.readFileSync(secondPath, "utf8");

assert(first.includes(`workspace-path:${workspaceRoot}/.clasp-local-planner/task-catalog.json:`), "fingerprint should include the workspace catalog path");
assert(second.includes(`workspace-path:${workspaceRoot}/.clasp-local-planner/task-catalog.json:`), "updated fingerprint should include the workspace catalog path");
assert(first.includes("goal:Harness planner input fingerprints should include reusable standalone swarm evidence."), "fingerprint should include the configured goal");
assert(first.includes("planner-policy:Harness planner policy"), "fingerprint should include the configured planner policy");
assert(first.includes("benchmark-summary:benchmark-summary-harness"), "fingerprint should include the benchmark summary");
assert(first.includes("planner-memory:planner memory harness line"), "fingerprint should include planner memory");
assert(first.includes("planner-backlog:planner backlog harness line"), "fingerprint should include planner backlog");
assert(first.includes("[planner-input-harness mailbox-task wave 1] mailbox summary harness line"), "fingerprint should include rendered mailbox summary");
assert(first.includes("  - capability-evidence=local_verifier_gate:harness mailbox evidence"), "fingerprint should include mailbox detail lines");
assert(first !== second, "rewriting the workspace planner catalog should invalidate planner report reuse");
NODE

cat >"$local_planner_goal_prompt" <<'EOF'
You are the planner subagent for the Clasp repository.
Plan the next bounded tasks needed to improve Clasp autonomously.

High-level goal:
Make Clasp the best language for AI agents to code and create agent swarms without Codex-specific control flow.

Planner context pack:
task: planner-1 status=ready ready=true attempts=0
dependency task ids:
- none
dependency task statuses:
- none
dependency task ready:
- none
artifact search matches:
- none
semantic index artifact matches:
- none
semantic index edit files:
- src/Compiler/Checker.clasp
semantic index surface ids:
- compiler:checker
benchmark history matches:
- none

Plan 1-3 bounded tasks with explicit dependencies and task prompts.
EOF

timeout "$timeout_secs" "$local_planner_bin" \
  --role planner \
  --schema "$project_root/agents/schemas/planner-report.schema.json" \
  --report "$local_planner_goal_report" \
  --prompt-path "$local_planner_goal_prompt" \
  --workspace "$local_planner_goal_workspace" \
  --log "$local_planner_goal_log" \
  >"$local_planner_goal_output"

node - "$local_planner_goal_report" "$local_planner_goal_log" "$local_planner_goal_workspace" <<'NODE'
const fs = require("node:fs");
const [reportPath, logPath, workspaceRoot] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const logEntries = fs.readFileSync(logPath, "utf8").trim().split(/\n/).filter(Boolean).map((line) => JSON.parse(line));

assert(report.objectiveSummary.includes("standalone-swarm"), `AI-agent swarm objective summary ${report.objectiveSummary}`);
assert(report.strategy.includes("ordinary-Clasp swarm-runtime"), `AI-agent swarm strategy ${report.strategy}`);
assert(report.tasks.length === 3, `AI-agent swarm task count ${report.tasks.length}`);
assert(report.tasks[0].taskId === "iteration-speed-loop", `AI-agent swarm first task ${report.tasks[0].taskId}`);
assert(report.tasks[1].taskId === "semantic-context-routing", `AI-agent swarm second task ${report.tasks[1].taskId}`);
assert(report.tasks[2].taskId === "standalone-swarm-readiness", `AI-agent swarm third task ${report.tasks[2].taskId}`);
assert(
  report.tasks[2].dependencies?.join(",") === "iteration-speed-loop,semantic-context-routing",
  `AI-agent swarm final dependencies ${report.tasks[2].dependencies}`,
);
assert(report.testsRun.includes("clasp-local-planner-heuristic-routing"), "AI-agent swarm planner should record heuristic routing coverage");
assert(logEntries.length === 1, `AI-agent swarm log entries ${logEntries.length}`);
assert(logEntries[0].backend === "clasp-local-planner", `AI-agent swarm backend ${logEntries[0].backend}`);
assert(logEntries[0].workspaceRoot === workspaceRoot, `AI-agent swarm workspace root ${logEntries[0].workspaceRoot}`);
NODE

cat >"$local_planner_audit_prompt" <<'EOF'
You are the planner subagent for the Clasp repository.
Plan the next bounded tasks needed to improve Clasp autonomously.

Planner context pack:
task: planner-1 status=ready ready=true attempts=1
dependency task ids:
- none
dependency task statuses:
- none
dependency task ready:
- none
artifact search matches:
- none
semantic index artifact matches:
- none
semantic index edit files:
- none
semantic index surface ids:
- none
benchmark history matches:
- none
Task file content:
Use this machine-readable audit to choose the next bounded closure task:
{"schema_version":1,"kind":"clasp-swarm-capability-audit","overall_status":"partial","capability_statuses":[{"name":"verification_gate","status":"partial","evidence":["focused checks"],"blocking_gaps":["bash scripts/verify-all.sh has not been proven"],"required_closure":["Run through scripts/run-managed-job.sh"]}],"blocking_gaps":["No current managed verify-all pass for the dirty tree."]}

Plan 1-3 bounded tasks with explicit dependencies and task prompts.
EOF

timeout "$timeout_secs" "$local_planner_bin" \
  --role planner \
  --schema "$project_root/agents/schemas/planner-report.schema.json" \
  --report "$local_planner_audit_report" \
  --prompt-path "$local_planner_audit_prompt" \
  --workspace "$local_planner_audit_workspace" \
  --log "$local_planner_audit_log" \
  >"$local_planner_audit_output"

node - "$local_planner_audit_report" "$local_planner_audit_log" "$local_planner_audit_workspace" <<'NODE'
const fs = require("node:fs");
const [reportPath, logPath, workspaceRoot] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const logEntries = fs.readFileSync(logPath, "utf8").trim().split(/\n/).filter(Boolean).map((line) => JSON.parse(line));

assert(report.objectiveSummary.includes("capability audit"), `capability audit objective summary ${report.objectiveSummary}`);
assert(report.strategy.includes("audit-closure"), `capability audit strategy ${report.strategy}`);
assert(report.tasks.length === 3, `capability audit task count ${report.tasks.length}`);
assert(report.tasks[0].taskId === "capability-audit-closure", `capability audit first task ${report.tasks[0].taskId}`);
assert(report.tasks[0].role === "swarm-audit-worker", `capability audit first role ${report.tasks[0].role}`);
assert(report.tasks[0].detail.includes("managed verification evidence gap"), `capability audit detail ${report.tasks[0].detail}`);
assert(report.tasks[0].taskPrompt.includes("managed verify-all evidence gap"), "capability audit task should preserve the concrete verify-all gap");
assert(report.tasks[0].taskPrompt.includes("scripts/run-managed-job.sh"), "capability audit task should require managed verification");
assert(report.tasks[0].taskPrompt.includes("CLASP_SWARM_CAPABILITY_VERIFY_REPORT_JSON"), "capability audit task should name the verification report env");
assert(report.tasks[0].coordinationFocus.includes("oom-safe-iteration"), "capability audit task should keep OOM-safe iteration in focus");
assert(report.tasks[0].coordinationFocus.includes("managed-verify-all"), "capability audit task should focus managed verify-all closure");
assert(report.tasks[1].taskId === "iteration-speed-loop", `capability audit second task ${report.tasks[1].taskId}`);
assert(report.tasks[2].taskId === "standalone-swarm-readiness", `capability audit third task ${report.tasks[2].taskId}`);
assert(
  report.tasks[2].dependencies?.join(",") === "capability-audit-closure,iteration-speed-loop",
  `capability audit final dependencies ${report.tasks[2].dependencies}`,
);
assert(report.testsRun.includes("clasp-local-planner-heuristic-routing"), "capability audit planner should record heuristic routing coverage");
assert(logEntries.length === 1, `capability audit log entries ${logEntries.length}`);
assert(logEntries[0].backend === "clasp-local-planner", `capability audit backend ${logEntries[0].backend}`);
assert(logEntries[0].workspaceRoot === workspaceRoot, `capability audit workspace root ${logEntries[0].workspaceRoot}`);
NODE

mkdir -p "$invalid_planner_workspace_root"
invalid_planner_workspace_json="$(json_string "$invalid_planner_workspace_root")"
XDG_CACHE_HOME="$test_root_abs/xdg-cache-invalid-planner" \
CLASP_LOOP_AGENT_BIN_JSON="$agent_bin_json" \
CLASP_LOOP_CODEX_BIN_JSON="$codex_bin_json" \
CLASP_LOOP_AGENT_COMMAND_JSON="$agent_command_json" \
CLASP_MANAGER_PLANNER_AGENT_COMMAND_JSON="$invalid_planner_command_json" \
CLASP_MANAGER_CLASPC_BIN_JSON="$child_claspc_json" \
CLASP_MANAGER_PROJECT_ROOT_JSON="$project_root_json" \
CLASP_LOOP_WORKSPACE_JSON="$invalid_planner_workspace_json" \
CLASP_MANAGER_GOAL_JSON="$goal_json" \
CLASP_MANAGER_OBJECTIVE_ID_JSON='"invalid-planner-backend"' \
CLASP_MANAGER_MAX_TASKS_JSON='1' \
CLASP_MANAGER_MAX_WAVES_JSON='1' \
CLASP_TEST_AGENT_LOG="$invalid_planner_agent_log" \
timeout "$timeout_secs" "$goal_manager_bin" "$invalid_planner_state_root" >"$invalid_planner_output_path"

CLASP_MANAGER_COMMAND=status \
timeout "$timeout_secs" "$goal_manager_bin" "$invalid_planner_state_root" >"$invalid_planner_status_path"

node - "$invalid_planner_output_path" "$invalid_planner_status_path" "$invalid_planner_agent_log" <<'NODE'
const fs = require("node:fs");
const [outputPath, statusPath, agentLogPath] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const output = JSON.parse(fs.readFileSync(outputPath, "utf8"));
const status = JSON.parse(fs.readFileSync(statusPath, "utf8"));

assert(output.state?.phase === "planner-failed", `invalid planner output phase ${output.state?.phase}`);
assert(output.state?.verdict === "fail", `invalid planner output verdict ${output.state?.verdict}`);
assert(output.plannerBackend?.kind === "template", `invalid backend kind ${output.plannerBackend?.kind}`);
assert(output.plannerBackend?.promptTransport === "missing", `invalid backend transport ${output.plannerBackend?.promptTransport}`);
assert(output.plannerBackend?.valid === false, "invalid planner backend should be marked invalid");
assert(output.plannerBackend?.validationMessage === "agent-backend-template-missing-prompt-input", `invalid planner backend message ${output.plannerBackend?.validationMessage}`);
assert(output.plannerBackendPolicy?.valid === false, "invalid planner backend policy should be marked invalid");
assert(
  output.plannerBackendPolicy?.validationMessages?.includes("agent-backend-template-missing-prompt-input"),
  `invalid planner backend policy messages ${output.plannerBackendPolicy?.validationMessages}`,
);
assert(
  output.plannerBackendPolicy?.blockingGaps?.includes("backend template does not pass the prompt through {prompt_path} or {prompt}"),
  `invalid planner backend policy gaps ${output.plannerBackendPolicy?.blockingGaps}`,
);
assert(
  output.plannerBackendPolicy?.missingPlaceholders?.includes("{prompt_path}"),
  `invalid planner backend policy missing placeholders ${output.plannerBackendPolicy?.missingPlaceholders}`,
);
assert(output.plannerBackendCapability?.profileName === "local-clasp", `invalid planner capability profile ${output.plannerBackendCapability?.profileName}`);
assert(output.plannerBackendCapability?.standaloneReady === false, "invalid planner capability should not be standalone-ready");
assert(
  output.plannerBackendCapability?.validationMessages?.includes("agent-backend-template-missing-prompt-input"),
  `invalid planner capability messages ${output.plannerBackendCapability?.validationMessages}`,
);
assert(status.state?.phase === "planner-failed", `invalid planner status phase ${status.state?.phase}`);
assert(status.plannerBackend?.promptTransport === "missing", `invalid planner status transport ${status.plannerBackend?.promptTransport}`);
assert(status.plannerBackendPolicy?.valid === false, "invalid planner status policy should be marked invalid");
assert(
  status.plannerBackendPolicy?.requiredClosure?.some((step) => step.includes("{prompt_path}")),
  `invalid planner status policy closure ${status.plannerBackendPolicy?.requiredClosure}`,
);
assert(status.plannerBackendCapability?.standaloneReady === false, "invalid planner status capability should be marked invalid");
assert(!fs.existsSync(agentLogPath), "invalid planner backend should fail before invoking the planner agent");
NODE

mkdir -p "$workspace_root"
XDG_CACHE_HOME="$test_root_abs/xdg-cache" \
CLASP_LOOP_AGENT_BIN_JSON="$agent_bin_json" \
CLASP_LOOP_CODEX_BIN_JSON="$codex_bin_json" \
CLASP_LOOP_AGENT_COMMAND_JSON="$agent_command_json" \
CLASP_MANAGER_PLANNER_AGENT_COMMAND_JSON="$planner_agent_command_json" \
CLASP_LOOP_AGENT_MEMORY_MB_JSON='2048' \
CLASP_MANAGER_PLANNER_MEMORY_MB_JSON='3072' \
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
assert(output.plannerBackend?.kind === "template", `manager output planner backend kind ${output.plannerBackend?.kind}`);
assert(output.plannerBackend?.promptTransport === "prompt-path", `manager output planner backend transport ${output.plannerBackend?.promptTransport}`);
assert(output.plannerBackend?.valid === true, "manager output planner backend should be valid");
assert(output.plannerBackendCapability?.profileName === "local-clasp", `manager output planner capability ${output.plannerBackendCapability?.profileName}`);
assert(output.plannerBackendCapability?.standaloneReady === true, "manager output planner capability should be standalone ready");
assert(status.state?.phase === "completed", `manager status phase ${status.state?.phase}`);
assert(status.state?.verdict === "pass" && status.state?.final === true, "manager status should persist pass");
assert(status.plannerBackend?.kind === "template", `manager status planner backend kind ${status.plannerBackend?.kind}`);
assert(status.plannerBackend?.promptTransport === "prompt-path", `manager status planner backend transport ${status.plannerBackend?.promptTransport}`);
assert(status.plannerBackendPolicy?.policyName === "default", `manager status planner policy ${status.plannerBackendPolicy?.policyName}`);
assert(status.plannerBackendPolicy?.backendKind === "template", `manager status planner policy backend ${status.plannerBackendPolicy?.backendKind}`);
assert(status.plannerBackendPolicy?.recommendedTemplate?.includes("{prompt_path}"), "manager status planner policy should include recommended template");
assert(status.plannerBackendCapability?.roleCoverage?.includes("planner"), "manager status planner capability should include planner coverage");
assert(status.plannerBackendCapability?.supportsChildTaskPlanning === true, "manager status planner capability should include child-task planning support");
assert(status.plannedTaskIds.includes("provider-neutral-child"), "manager should track the generic planner task");
assert(status.completedTaskIds.includes("provider-neutral-child"), "planned child task should complete");
assert(status.objectiveProjectedStatus === "completed", `objective projected ${status.objectiveProjectedStatus}`);
assert(planner.tasks.length === 1 && planner.tasks[0].taskId === "provider-neutral-child", "planner report should come from generic planner");
assert(planner.tasks[0].taskPrompt.includes("native planner context pack"), "Clasp planner task should consume native context pack evidence");
assert(planner.tasks[0].coordinationFocus.includes("native-context-pack"), "Clasp planner task should tag native context-pack coordination");
assert(planner.testsRun.includes("clasp-local-planner-context-pack"), "Clasp planner report should record context-pack coverage");
assert(planner.testsRun.includes("clasp-local-planner-backend-policy-repair"), "Clasp planner report should record backend policy repair coverage");
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

multi_state_root="$test_root_abs/multi-state"
multi_workspace_root="$test_root_abs/multi-workspace"
multi_agent_log="$test_root_abs/multi-agent-invocations.jsonl"
multi_child_log="$test_root_abs/multi-child-env.jsonl"
multi_output_path="$test_root_abs/multi-output.json"
multi_status_path="$test_root_abs/multi-status.json"
multi_workspace_json="$(json_string "$multi_workspace_root")"
multi_goal_json="$(json_string "Improve iteration speed and semantic context for standalone swarm readiness.")"

mkdir -p "$multi_workspace_root"
XDG_CACHE_HOME="$test_root_abs/xdg-cache-multi" \
CLASP_LOOP_AGENT_BIN_JSON="$agent_bin_json" \
CLASP_LOOP_CODEX_BIN_JSON="$codex_bin_json" \
CLASP_LOOP_AGENT_COMMAND_JSON="$agent_command_json" \
CLASP_MANAGER_PLANNER_AGENT_COMMAND_JSON="$planner_agent_command_json" \
CLASP_LOOP_AGENT_MEMORY_MB_JSON='2048' \
CLASP_MANAGER_PLANNER_MEMORY_MB_JSON='3072' \
CLASP_LOOP_BUILDER_MEMORY_MB_JSON='1024' \
CLASP_LOOP_VERIFIER_MEMORY_MB_JSON='1536' \
CLASP_MANAGER_CLASPC_BIN_JSON="$child_claspc_json" \
CLASP_MANAGER_PROJECT_ROOT_JSON="$project_root_json" \
CLASP_LOOP_WORKSPACE_JSON="$multi_workspace_json" \
CLASP_MANAGER_GOAL_JSON="$multi_goal_json" \
CLASP_MANAGER_OBJECTIVE_ID_JSON='"standalone-routed-manager"' \
CLASP_MANAGER_MAX_TASKS_JSON='3' \
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
CLASP_TEST_AGENT_LOG="$multi_agent_log" \
CLASP_TEST_CHILD_ENV_LOG="$multi_child_log" \
CLASP_TEST_EXPECT_CHILD_AGENT_COMMAND_JSON="$agent_command_json" \
CLASP_TEST_EXPECT_AGENT_BIN_JSON="$agent_bin_json" \
timeout "$timeout_secs" "$goal_manager_bin" "$multi_state_root" >"$multi_output_path"

CLASP_MANAGER_COMMAND=status \
timeout "$timeout_secs" "$goal_manager_bin" "$multi_state_root" >"$multi_status_path"

node - "$multi_output_path" "$multi_status_path" "$multi_agent_log" "$multi_child_log" "$multi_state_root" "$multi_workspace_root" "$codex_marker" "$swarm_proof_report_path" <<'NODE'
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
  proofReportPath,
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
const expectedTasks = [
  ["iteration-speed-loop", "iteration-speed-child-ok"],
  ["semantic-context-routing", "semantic-context-child-ok"],
  ["standalone-swarm-readiness", "standalone-swarm-child-ok"],
];

assert(output.state?.phase === "completed", `multi manager output phase ${output.state?.phase}`);
assert(output.state?.verdict === "pass" && output.state?.final === true, "multi manager output should finish with pass");
assert(status.state?.phase === "completed", `multi manager status phase ${status.state?.phase}`);
assert(status.state?.verdict === "pass" && status.state?.final === true, "multi manager status should persist pass");
assert(planner.tasks.length === 3, `multi planner task count ${planner.tasks.length}`);
assert(
  planner.tasks[2]?.dependencies?.join(",") === "iteration-speed-loop,semantic-context-routing",
  `multi final task dependencies ${planner.tasks[2]?.dependencies}`,
);
assert(planner.testsRun.includes("clasp-local-planner-heuristic-routing"), "multi planner report should record heuristic routing coverage");
assert(agentInvocations.length === 1, `expected one multi planner invocation, saw ${agentInvocations.length}`);
assert(agentInvocations[0].backend === "clasp-local-planner", "multi GoalManager should use the Clasp-native planner backend");
assert(childInvocations.length === 3, `expected three child loop invocations, saw ${childInvocations.length}`);
assert(childInvocations[0].taskRoute !== "standalone-swarm-readiness", "dependent standalone task should not launch before its prerequisites");
assert(childInvocations[2].taskRoute === "standalone-swarm-readiness", "dependent standalone task should launch after prerequisite routes");
const standalonePrompt = fs.readFileSync(childInvocations[2].taskFile, "utf8");
assert(standalonePrompt.includes("direct source edit"), "dependent standalone prompt should carry source-edit requirement");
assert(standalonePrompt.includes("direct-source-edit"), "dependent standalone prompt should carry source-edit proof marker");
assert(standalonePrompt.includes("multi-surface"), "dependent standalone prompt should carry multi-surface source-edit requirement");
assert(standalonePrompt.includes("multi-surface-source-patch"), "dependent standalone prompt should carry multi-surface source-patch marker");
assert(standalonePrompt.includes("repo-scale-source-patch"), "dependent standalone prompt should carry repo-scale source-patch marker");
assert(standalonePrompt.includes("scripts/standalone-swarm-verify.sh --closure --json"), "dependent standalone prompt should carry JSON closure verifier");
assert(standalonePrompt.includes("Source edit plan:"), "dependent standalone prompt should carry source edit plan");
assert(standalonePrompt.includes("Source edit patches:"), "dependent standalone prompt should carry source patch plan");
assert(standalonePrompt.includes("src/StandaloneSwarmReadiness.clasp"), "dependent standalone prompt should carry readiness source file");
assert(standalonePrompt.includes("src/StandaloneSwarmVerifier.clasp"), "dependent standalone prompt should carry verifier source file");
assert(standalonePrompt.includes("examples/swarm-native/StandaloneSwarmHarness.clasp"), "dependent standalone prompt should carry harness source file");
assert(standalonePrompt.includes("examples/swarm-native/StandaloneSwarmRouting.clasp"), "dependent standalone prompt should carry routing source file");
assert(standalonePrompt.includes("scripts/standalone-swarm-readiness.sh"), "dependent standalone prompt should carry script source file");
assert(standalonePrompt.includes("scripts/standalone-swarm-verify.sh"), "dependent standalone prompt should carry verifier script source file");
assert(standalonePrompt.includes("docs/standalone-swarm-readiness.md"), "dependent standalone prompt should carry doc source file");
assert(standalonePrompt.includes("runtime/standalone_swarm_probe.rs"), "dependent standalone prompt should carry runtime source file");
assert(standalonePrompt.includes('readinessStatus = "open" => readinessStatus = "standalone-swarm-fixed-after-feedback"'), "dependent standalone prompt should carry readiness patch");
assert(standalonePrompt.includes('verifierStatus = "open" => verifierStatus = "standalone-swarm-fixed-after-feedback"'), "dependent standalone prompt should carry verifier patch");
assert(standalonePrompt.includes('harnessStatus = "open" => harnessStatus = "standalone-swarm-fixed-after-feedback"'), "dependent standalone prompt should carry harness patch");
assert(standalonePrompt.includes('routingStatus = "open" => routingStatus = "standalone-swarm-fixed-after-feedback"'), "dependent standalone prompt should carry routing patch");
assert(standalonePrompt.includes('echo "standalone-swarm=open" => echo "standalone-swarm=standalone-swarm-fixed-after-feedback"'), "dependent standalone prompt should carry script patch");
assert(standalonePrompt.includes('echo "standalone-swarm-verifier=open" => echo "standalone-swarm-verifier=standalone-swarm-fixed-after-feedback"'), "dependent standalone prompt should carry verifier script patch");
assert(standalonePrompt.includes("standalone-swarm-status: open => standalone-swarm-status: standalone-swarm-fixed-after-feedback"), "dependent standalone prompt should carry doc patch");
assert(standalonePrompt.includes('STANDALONE_SWARM_STATUS: &str = "open"'), "dependent standalone prompt should carry runtime patch");
assert(standalonePrompt.includes("Dependency completion evidence:"), "dependent standalone prompt should include dependency evidence section");
assert(
  standalonePrompt.includes("- iteration-speed-loop verifier=pass summary=generic child loop completed"),
  "dependent standalone prompt should include iteration-speed verifier evidence",
);
assert(
  standalonePrompt.includes("- semantic-context-routing verifier=pass summary=generic child loop completed"),
  "dependent standalone prompt should include semantic-context verifier evidence",
);
assert(standalonePrompt.includes("builder=missing"), "dependent standalone prompt should name missing builder report evidence");
for (const [index, [taskId, content]] of expectedTasks.entries()) {
  assert(planner.tasks[index]?.taskId === taskId, `planned task ${index} ${planner.tasks[index]?.taskId}`);
  assert(status.plannedTaskIds.includes(taskId), `status missing planned task ${taskId}`);
  assert(status.completedTaskIds.includes(taskId), `status missing completed task ${taskId}`);
  assert(childInvocations.some((entry) => entry.taskRoute === taskId), `child log missing route ${taskId}`);
  const finalWorkspace = path.join(workspaceRoot, ".clasp-task-workspaces", taskId);
  assert(fs.readFileSync(path.join(finalWorkspace, "workspace.txt"), "utf8").trim() === content, `workspace content for ${taskId}`);
  assert(fs.readFileSync(path.join(finalWorkspace, "notes", "local-planner-route.txt"), "utf8").trim() === taskId, `route artifact for ${taskId}`);
}
assert(feedback.tests_run?.includes("goal-manager-local-planner-routed-child"), "feedback should include routed child coverage");
assert(
  feedback.capability_statuses?.some((entry) =>
    entry.evidence?.includes("child loop executed local planner route: iteration-speed-loop")
  ),
  "feedback should preserve first routed child evidence",
);
assert(!fs.existsSync(codexMarker), "Codex fallback backend should not be invoked for multi-task planner run");
if (proofReportPath) {
  fs.mkdirSync(path.dirname(proofReportPath), { recursive: true });
  const proof = {
    schemaVersion: 1,
    kind: "clasp-managed-swarm-proof",
    verdict: "pass",
    managerCompleted: output.state?.phase === "completed" && status.state?.phase === "completed",
    managerFinal: output.state?.final === true && status.state?.final === true,
    plannerBackendKind: status.plannerBackend?.kind || output.plannerBackend?.kind || "",
    plannerBackendTransport: status.plannerBackend?.promptTransport || output.plannerBackend?.promptTransport || "",
    codexFallbackInvoked: fs.existsSync(codexMarker),
    taskCount: planner.tasks.length,
    completedTaskCount: expectedTasks.filter(([taskId]) => status.completedTaskIds.includes(taskId)).length,
    dependencyOrdered: childInvocations[0].taskRoute !== "standalone-swarm-readiness" && childInvocations[2].taskRoute === "standalone-swarm-readiness",
    localPlannerBackend: agentInvocations[0].backend === "clasp-local-planner",
    localAgentCommandPropagated: childInvocations.every((entry) => entry.agentCommandJson && entry.agentBinJson),
    sourceEditPlanDelivered: standalonePrompt.includes("Source edit plan:"),
    sourcePatchPlanDelivered: standalonePrompt.includes("Source edit patches:"),
    dependencyEvidenceDelivered: standalonePrompt.includes("Dependency completion evidence:"),
    taskIds: planner.tasks.map((task) => task.taskId),
    completedTaskIds: status.completedTaskIds,
    evidence: [
      "GoalManager completed a three-task local planner run.",
      "The final standalone-swarm task launched after iteration-speed and semantic-context prerequisites.",
      "No Codex fallback marker was written.",
      "The final task prompt carried dependency evidence plus source-edit and source-patch plans.",
    ],
  };
  fs.writeFileSync(proofReportPath, `${JSON.stringify(proof, null, 2)}\n`);
}
NODE

printf 'goal-manager-agent-command-template-ok\n'
