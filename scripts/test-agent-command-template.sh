#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_AGENT_COMMAND_TEMPLATE_TIMEOUT_SECS:-300}"
run_feedback_template="${CLASP_AGENT_COMMAND_TEMPLATE_FEEDBACK:-1}"
run_native_template="${CLASP_AGENT_COMMAND_TEMPLATE_NATIVE:-0}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_AGENT_COMMAND_TEMPLATE_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

case "$run_feedback_template" in
  0|1)
    ;;
  *)
    printf 'CLASP_AGENT_COMMAND_TEMPLATE_FEEDBACK must be 0 or 1\n' >&2
    exit 1
    ;;
esac

case "$run_native_template" in
  0|1)
    ;;
  *)
    printf 'CLASP_AGENT_COMMAND_TEMPLATE_NATIVE must be 0 or 1\n' >&2
    exit 1
    ;;
esac

if [[ "$run_feedback_template" == "0" && "$run_native_template" == "0" ]]; then
  printf 'at least one agent command template scenario must be enabled\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-agent-command-template.XXXXXX")"
state_root="$test_root/state"
workspace_root="$test_root/workspace"
native_state_root="$test_root/native-state"
native_workspace_root="$test_root/native-workspace"
task_file="$test_root/task.md"
fake_agent="$test_root/generic-agent"
output_path="$test_root/output.txt"
status_path="$test_root/status.json"
native_output_path="$test_root/native-output.json"
native_status_path="$test_root/native-status.json"
local_agent_state_root="$test_root/local-agent-state"
local_agent_workspace_root="$test_root/local-agent-workspace"
local_agent_output_path="$test_root/local-agent-output.json"
local_agent_status_path="$test_root/local-agent-status.json"
agent_log="$test_root/agent-invocations.jsonl"
native_agent_log="$test_root/native-agent-invocations.jsonl"

cleanup() {
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root" >&2
  else
    rm -rf "$test_root" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

cat >"$task_file" <<'EOF'
Prove a generic non-Codex agent command template can run the Clasp feedback loop.
EOF

cat >"$fake_agent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

role=""
report_path=""
prompt_path=""
prompt=""
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
    --prompt)
      prompt="${2:-}"
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

if [[ -z "$role" || -z "$report_path" ]]; then
  printf 'missing required generic-agent arguments\n' >&2
  exit 65
fi

if [[ -n "$prompt_path" ]]; then
  prompt="$(cat "$prompt_path")"
fi

if [[ -z "$prompt" ]]; then
  printf 'missing required generic-agent prompt\n' >&2
  exit 65
fi

mkdir -p "$(dirname "$report_path")" "$workspace_root"
printf '{"role":%s,"reportPath":%s,"promptPath":%s,"schemaPath":%s}\n' \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$role")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$report_path")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$prompt_path")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$schema_path")" \
  >> "${CLASP_TEST_AGENT_LOG:?}"

case "$role" in
  builder)
    if [[ "$prompt" != *"builder subagent"* ]]; then
      printf 'builder prompt was not supplied\n' >&2
      exit 66
    fi
    printf 'generic-agent-template-ok\n' >"$workspace_root/generic-agent.txt"
    cat >"$report_path" <<'JSON'
{"summary":"generic builder completed","files_touched":["generic-agent.txt"],"tests_run":["generic-agent-template"],"residual_risks":[],"feedback":{"summary":"generic builder feedback","ergonomics":["provider-neutral agent command template worked"],"follow_ups":[],"warnings":[]}}
JSON
    ;;
  verifier)
    if [[ "$prompt" != *"verifier subagent"* ]]; then
      printf 'verifier prompt was not supplied\n' >&2
      exit 67
    fi
    if [[ "$(cat "$workspace_root/generic-agent.txt")" != "generic-agent-template-ok" ]]; then
      printf 'builder artifact missing from workspace\n' >&2
      exit 68
    fi
    cat >"$report_path" <<'JSON'
{"verdict":"pass","summary":"generic verifier passed","findings":[],"tests_run":["generic-agent-template"],"follow_up":[],"capability_statuses":[{"name":"provider_neutral_agent_runner","status":"pass","evidence":["CLASP_LOOP_AGENT_COMMAND_JSON launched a non-Codex agent command"],"blocking_gaps":[],"required_closure":[]}]}
JSON
    ;;
  *)
    printf 'unknown role: %s\n' "$role" >&2
    exit 69
    ;;
esac
EOF
chmod +x "$fake_agent"

if [[ -n "${CLASP_CLASPC:-}" ]]; then
  claspc_bin="$CLASP_CLASPC"
elif [[ -n "${CLASPC_BIN:-}" ]]; then
  claspc_bin="$CLASPC_BIN"
else
  claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN CLASP_PROJECT_ROOT="$project_root" "$project_root/scripts/resolve-claspc.sh")"
fi

agent_bin_json="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$fake_agent")"
claspc_bin_json="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$claspc_bin")"
agent_command_json="$(
  node - <<'NODE'
process.stdout.write(JSON.stringify([
  "{agent_bin}",
  "--role",
  "{role}",
  "--schema",
  "{schema_path}",
  "--report",
  "{report_path}",
  "--prompt-path",
  "{prompt_path}",
  "--workspace",
  "{workspace_root}",
  "--model",
  "{model}",
  "--reasoning",
  "{reasoning}",
  "--sandbox",
  "{sandbox}"
]));
NODE
)"

native_agent_command_json="$(
  node - <<'NODE'
process.stdout.write(JSON.stringify([
  "{agent_bin}",
  "--role",
  "{role}",
  "--schema",
  "{schema_path}",
  "--report",
  "{report_path}",
  "--prompt",
  "{prompt}",
  "--workspace",
  "{workspace_root}",
  "--model",
  "{model}",
  "--reasoning",
  "{reasoning}",
  "--sandbox",
  "{sandbox}"
]));
NODE
)"

local_agent_command_json="$(
  node - "$project_root/examples/swarm-native/LocalAgent.clasp" <<'NODE'
const localAgentPath = process.argv[2];
process.stdout.write(JSON.stringify([
  "{agent_bin}",
  "run",
  localAgentPath,
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

grep -F 'CLASP_LOOP_AGENT_COMMAND_JSON' "$project_root/examples/feedback-loop/Main.clasp" >/dev/null
grep -F 'CLASP_LOOP_AGENT_COMMAND_JSON' "$project_root/examples/swarm-native/FeedbackLoop.clasp" >/dev/null
grep -F '{prompt_path}' "$project_root/examples/swarm-native/FeedbackLoop.clasp" >/dev/null
grep -F 'local Clasp builder backend completed' "$project_root/examples/swarm-native/LocalAgent.clasp" >/dev/null
grep -F 'CLASP_MANAGER_PLANNER_AGENT_COMMAND_JSON' "$project_root/examples/swarm-native/GoalManagerConfig.clasp" >/dev/null
grep -F 'plannerAgentCommandArgs' "$project_root/examples/swarm-native/GoalManagerBootstrapPlanner.clasp" >/dev/null
grep -F 'CLASP_LOOP_AGENT_COMMAND_JSON' "$project_root/examples/swarm-native/GoalManagerServiceMain.clasp" >/dev/null

if [[ "$run_feedback_template" == "1" ]]; then
  mkdir -p "$workspace_root"
  CLASP_LOOP_AGENT_BIN_JSON="$agent_bin_json" \
    CLASP_LOOP_AGENT_COMMAND_JSON="$agent_command_json" \
    CLASP_LOOP_TASK_FILE_JSON="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$task_file")" \
    CLASP_LOOP_WORKSPACE_JSON="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$workspace_root")" \
    CLASP_LOOP_MAX_ATTEMPTS_JSON='1' \
    CLASP_TEST_AGENT_LOG="$agent_log" \
    timeout "$timeout_secs" "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$state_root" >"$output_path"

  CLASP_LOOP_COMMAND=status \
    timeout "$timeout_secs" "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$state_root" >"$status_path"

  node - "$output_path" "$status_path" "$agent_log" "$workspace_root/generic-agent.txt" <<'NODE'
const fs = require("node:fs");
const [outputPath, statusPath, agentLog, workspaceArtifact] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const output = fs.readFileSync(outputPath, "utf8").trim();
const status = JSON.parse(fs.readFileSync(statusPath, "utf8"));
const artifact = fs.readFileSync(workspaceArtifact, "utf8").trim();
const invocations = fs
  .readFileSync(agentLog, "utf8")
  .trim()
  .split(/\n/)
  .filter(Boolean)
  .map((line) => JSON.parse(line));

assert(output === "pass:1", `unexpected loop output: ${output}`);
assert(status.verdict === "pass" && status.completed === true && status.final === true, "loop should persist a passing final status");
assert(artifact === "generic-agent-template-ok", "generic builder should update the workspace");
assert(invocations.map((entry) => entry.role).join(",") === "builder,verifier", "generic agent should run builder then verifier");
for (const invocation of invocations) {
  assert(!invocation.reportPath.includes("codex"), "generic template should not need Codex-named report paths");
  assert(invocation.promptPath.endsWith(".md"), "generic template should receive durable prompt path");
}
NODE
fi

if [[ "$run_native_template" == "1" ]]; then
  mkdir -p "$native_workspace_root"
  CLASP_LOOP_AGENT_BIN_JSON="$agent_bin_json" \
    CLASP_LOOP_AGENT_COMMAND_JSON="$native_agent_command_json" \
    CLASP_LOOP_TASK_FILE_JSON="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$task_file")" \
    CLASP_LOOP_WORKSPACE_JSON="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$native_workspace_root")" \
    CLASP_LOOP_MAX_ATTEMPTS_JSON='1' \
    CLASP_TEST_AGENT_LOG="$native_agent_log" \
    timeout "$timeout_secs" "$claspc_bin" run "$project_root/examples/swarm-native/FeedbackLoop.clasp" -- "$native_state_root" >"$native_output_path"

  CLASP_LOOP_COMMAND=status \
    timeout "$timeout_secs" "$claspc_bin" run "$project_root/examples/swarm-native/FeedbackLoop.clasp" -- "$native_state_root" >"$native_status_path"

  node - "$native_output_path" "$native_status_path" "$native_agent_log" "$native_workspace_root/generic-agent.txt" <<'NODE'
const fs = require("node:fs");
const [outputPath, statusPath, agentLog, workspaceArtifact] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const output = JSON.parse(fs.readFileSync(outputPath, "utf8"));
const status = JSON.parse(fs.readFileSync(statusPath, "utf8"));
const artifact = fs.readFileSync(workspaceArtifact, "utf8").trim();
const invocations = fs
  .readFileSync(agentLog, "utf8")
  .trim()
  .split(/\n/)
  .filter(Boolean)
  .map((line) => JSON.parse(line));

assert(output.state?.phase === "completed", `native phase ${output.state?.phase}`);
assert(output.state?.verdict === "pass" && output.state?.final === true, "native loop should finish with a pass");
assert(output.objectiveProjectedStatus === "completed", `native projected ${output.objectiveProjectedStatus}`);
assert(output.taskCount === 2, `native task count ${output.taskCount}`);
assert(output.approvalCount === 1, `native approval count ${output.approvalCount}`);
assert(output.mergeGateSatisfied === true, "native merge gate should be satisfied");
assert(status.state?.phase === "completed", `native status phase ${status.state?.phase}`);
assert(status.state?.verdict === "pass" && status.state?.final === true, "native status should persist a passing final status");
assert(artifact === "generic-agent-template-ok", "native generic builder should update the workspace");
assert(invocations.map((entry) => entry.role).join(",") === "builder,verifier", "native generic agent should run builder then verifier");
  for (const invocation of invocations) {
    assert(!invocation.reportPath.includes("codex"), "native generic template should not need Codex-named report paths");
    assert(invocation.promptPath === "", "native generic template should receive an inline prompt");
  }
NODE

  mkdir -p "$local_agent_workspace_root"
  CLASP_LOOP_AGENT_BIN_JSON="$claspc_bin_json" \
    CLASP_LOOP_AGENT_COMMAND_JSON="$local_agent_command_json" \
    CLASP_LOOP_TASK_FILE_JSON="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$task_file")" \
    CLASP_LOOP_WORKSPACE_JSON="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$local_agent_workspace_root")" \
    CLASP_LOOP_MAX_ATTEMPTS_JSON='2' \
    timeout "$timeout_secs" "$claspc_bin" run "$project_root/examples/swarm-native/FeedbackLoop.clasp" -- "$local_agent_state_root" >"$local_agent_output_path"

  CLASP_LOOP_COMMAND=status \
    timeout "$timeout_secs" "$claspc_bin" run "$project_root/examples/swarm-native/FeedbackLoop.clasp" -- "$local_agent_state_root" >"$local_agent_status_path"

  node - "$local_agent_output_path" "$local_agent_status_path" "$local_agent_workspace_root/workspace.txt" "$local_agent_state_root/builder-2.json" "$local_agent_state_root/verifier-1.json" "$local_agent_state_root/verifier-2.json" "$local_agent_state_root/builder-2.prompt.md" "$local_agent_state_root/verifier-2.prompt.md" <<'NODE'
const fs = require("node:fs");
const [
  outputPath,
  statusPath,
  workspacePath,
  secondBuilderReportPath,
  firstVerifierReportPath,
  secondVerifierReportPath,
  secondBuilderPromptPath,
  secondVerifierPromptPath,
] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function readJson(path) {
  return JSON.parse(fs.readFileSync(path, "utf8"));
}

const output = readJson(outputPath);
const status = readJson(statusPath);
const workspaceText = fs.readFileSync(workspacePath, "utf8");
const secondBuilder = readJson(secondBuilderReportPath);
const firstVerifier = readJson(firstVerifierReportPath);
const secondVerifier = readJson(secondVerifierReportPath);
const secondBuilderPrompt = fs.readFileSync(secondBuilderPromptPath, "utf8");
const secondVerifierPrompt = fs.readFileSync(secondVerifierPromptPath, "utf8");

assert(output.state?.phase === "completed", `local agent phase ${output.state?.phase}`);
assert(output.state?.attempt === 2, `local agent attempt ${output.state?.attempt}`);
assert(output.state?.verdict === "pass" && output.state?.final === true, "local agent loop should finish with a pass");
assert(output.objectiveProjectedStatus === "completed", `local projected ${output.objectiveProjectedStatus}`);
assert(status.state?.phase === "completed", `local status phase ${status.state?.phase}`);
assert(status.previousVerifierFeedback?.present === true, "local status should persist previous verifier feedback");
assert(workspaceText === "fixed-after-feedback\n", "local Clasp builder should consume verifier feedback");
assert(secondBuilder.feedback?.summary === "local Clasp builder backend completed", "second builder report should come from LocalAgent.clasp");
assert(firstVerifier.verdict === "fail", `first local verifier verdict ${firstVerifier.verdict}`);
assert(secondVerifier.verdict === "pass", `second local verifier verdict ${secondVerifier.verdict}`);
assert(secondBuilderPrompt.includes("Verifier feedback from the previous attempt:"), "second builder prompt should be persisted for prompt-path agents");
assert(secondBuilderPrompt.includes("force-close-category"), "second builder prompt should include persisted verifier feedback");
assert(secondBuilderPrompt.includes("Swarm context pack:"), "second builder prompt should include native context pack evidence");
assert(secondBuilderPrompt.includes("task: builder-2"), "second builder prompt should identify the builder task context");
assert(secondBuilderPrompt.includes("verifier-feedback"), "second builder prompt should include persisted verifier feedback memory");
assert(secondVerifierPrompt.includes("verifier subagent"), "second verifier prompt should be persisted for prompt-path agents");
assert(secondVerifierPrompt.includes("Swarm context pack:"), "second verifier prompt should include native context pack evidence");
assert(secondVerifierPrompt.includes("task: verifier-2"), "second verifier prompt should identify the verifier task context");
assert(secondVerifierPrompt.includes("run trace:"), "second verifier prompt should include run trace context");
assert(
  secondVerifier.capability_statuses?.some((entry) => entry.name === "clasp_native_agent_backend" && entry.status === "pass"),
  "local verifier should prove the Clasp-native agent backend capability",
);
NODE

  printf 'native-clasp-local-agent-template-ok\n'
  printf 'native-provider-neutral-agent-template-ok\n'
fi

printf 'agent-command-template-ok\n'
