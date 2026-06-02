#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_AGENT_COMMAND_TEMPLATE_TIMEOUT_SECS:-700}"
run_feedback_template="${CLASP_AGENT_COMMAND_TEMPLATE_FEEDBACK:-1}"
run_native_template="${CLASP_AGENT_COMMAND_TEMPLATE_NATIVE:-0}"
run_common_template="${CLASP_AGENT_COMMAND_TEMPLATE_COMMON:-1}"

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

case "$run_common_template" in
  0|1)
    ;;
  *)
    printf 'CLASP_AGENT_COMMAND_TEMPLATE_COMMON must be 0 or 1\n' >&2
    exit 1
    ;;
esac

if [[ "$run_feedback_template" == "0" && "$run_native_template" == "0" && "$run_common_template" == "0" ]]; then
  printf 'at least one agent command template scenario must be enabled\n' >&2
  exit 1
fi

export CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE="${CLASP_NATIVE_IMAGE_MODULE_DECL_CHUNK_SIZE:-8}"

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
local_agent_route_root="$test_root/local-agent-route"
local_agent_route_workspace="$test_root/local-agent-route-workspace"
local_agent_dependency_root="$test_root/local-agent-dependency"
local_agent_dependency_workspace="$test_root/local-agent-dependency-workspace"
local_agent_goal_root="$test_root/local-agent-ai-agent-swarm-goal"
local_agent_goal_workspace="$test_root/local-agent-ai-agent-swarm-goal-workspace"
agent_log="$test_root/agent-invocations.jsonl"
native_agent_log="$test_root/native-agent-invocations.jsonl"
native_invalid_template_output_path="$test_root/native-invalid-template-output.txt"

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
prompt_has_task_content=false
prompt_has_task_text=false
if [[ "$prompt" == *"Task file content:"* ]]; then
  prompt_has_task_content=true
fi
if [[ "$prompt" == *"Prove a generic non-Codex agent command template can run the Clasp feedback loop."* ]]; then
  prompt_has_task_text=true
fi
printf '{"role":%s,"reportPath":%s,"promptPath":%s,"schemaPath":%s,"promptHasTaskFileContent":%s,"promptHasTaskText":%s}\n' \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$role")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$report_path")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$prompt_path")" \
  "$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$schema_path")" \
  "$prompt_has_task_content" \
  "$prompt_has_task_text" \
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

if [[ "$run_common_template" == "1" ]]; then
  agent_backend_output="$test_root/agent-backend.json"
  timeout "$timeout_secs" "$claspc_bin" run "$project_root/examples/swarm-native/AgentBackendHarness.clasp" >"$agent_backend_output"
  node - "$agent_backend_output" <<'NODE'
const fs = require("node:fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

assert(report.templateCommand[0] === "local-agent", `template command bin ${report.templateCommand[0]}`);
assert(report.templateCommand.includes("--prompt-path"), "template command should include prompt path placeholder");
assert(report.templateCommand.includes("state/builder.prompt.md"), "template command should render prompt path");
assert(report.templateCommand.includes("Fix the native swarm task."), "template command should render prompt text");
assert(report.templateCommand.includes("/workspace"), "template command should render workspace root");
assert(report.claspRunCommand[0] === "claspc", `Clasp run command bin ${report.claspRunCommand[0]}`);
assert(report.claspRunCommand[1] === "run", "Clasp run backend should use the ordinary run entrypoint");
assert(
  report.claspRunCommand.includes("examples/swarm-native/LocalAgent.clasp"),
  `Clasp run command program ${report.claspRunCommand.join(" ")}`,
);
assert(report.claspRunCommand.includes("--"), "Clasp run command should separate program args");
assert(report.claspRunCommand.includes("--prompt-path"), "Clasp run command should use durable prompt-path transport");
assert(report.claspRunCommand.includes("state/builder.prompt.md"), "Clasp run command should render prompt path");
assert(report.claspRunCommand.includes("schemas/builder.json"), "Clasp run command should render schema path");
assert(report.claspRunCommand.includes("/workspace"), "Clasp run command should render workspace root");
assert(
  report.localAgentTemplate.includes("examples/swarm-native/LocalAgent.clasp"),
  `local agent template ${report.localAgentTemplate.join(" ")}`,
);
assert(
  report.localPlannerTemplate.includes("examples/swarm-native/LocalPlanner.clasp"),
  `local planner template ${report.localPlannerTemplate.join(" ")}`,
);
assert(report.codexCommand[0] === "codex", `codex command bin ${report.codexCommand[0]}`);
assert(report.codexCommand.includes("gpt-5.5"), "codex command should include model");
assert(report.codexCommand.includes("model_reasoning_effort=\"xhigh\""), "codex command should include reasoning config");
assert(report.codexCommand.includes("danger-full-access"), "codex command should include sandbox");
assert(report.codexCommand.includes("schemas/builder.json"), "codex command should include schema");
assert(report.codexCommand.includes("state/builder.json"), "codex command should include report path");
assert(report.codexCommand.at(-1) === "Fix the native swarm task.", "codex command should pass prompt as final arg");
assert(
  report.renderedArg === "role=builder;prompt=Fix the native swarm task.;workspace=/workspace",
  `rendered arg ${report.renderedArg}`,
);
assert(report.reasoningConfig === "model_reasoning_effort=\"xhigh\"", `reasoning ${report.reasoningConfig}`);
assert(report.templateSummary.kind === "template", `template kind ${report.templateSummary.kind}`);
assert(report.templateSummary.promptTransport === "prompt-path+inline", `template prompt transport ${report.templateSummary.promptTransport}`);
assert(report.templateSummary.valid === true, "template backend should be valid");
assert(report.templateSummary.templateArgCount > 0, "template summary should report args");
assert(report.templateSummary.hasRoleInput === true, "template summary should report role transport");
assert(report.templateSummary.hasPromptPathInput === true, "template summary should report prompt path transport");
assert(report.templateSummary.hasInlinePromptInput === true, "template summary should report inline prompt transport");
assert(report.templateSummary.hasReportOutput === true, "template summary should report report output transport");
assert(report.templateSummary.hasSchemaInput === true, "template summary should report schema transport");
assert(report.templateSummary.hasWorkspaceInput === true, "template summary should report workspace transport");
assert(report.templateSummary.hasModelInput === true, "template summary should report model transport");
assert(report.claspRunSummary.kind === "template", `Clasp run summary kind ${report.claspRunSummary.kind}`);
assert(report.claspRunSummary.promptTransport === "prompt-path", `Clasp run prompt transport ${report.claspRunSummary.promptTransport}`);
assert(report.claspRunSummary.valid === true, "Clasp run backend should be valid");
assert(report.claspRunSummary.hasRoleInput === true, "Clasp run backend should pass role");
assert(report.claspRunSummary.hasPromptPathInput === true, "Clasp run backend should pass prompt path");
assert(report.claspRunSummary.hasInlinePromptInput === false, "Clasp run backend should not require inline prompt args");
assert(report.claspRunSummary.hasReportOutput === true, "Clasp run backend should pass report path");
assert(report.claspRunSummary.hasSchemaInput === true, "Clasp run backend should pass schema path");
assert(report.claspRunSummary.hasWorkspaceInput === true, "Clasp run backend should pass workspace root");
assert(report.claspRunSummary.hasModelInput === true, "Clasp run backend should pass model");
assert(report.claspRunSummary.hasReasoningInput === true, "Clasp run backend should pass reasoning");
assert(report.localAgentSpecSummary.kind === "template", `local agent spec kind ${report.localAgentSpecSummary.kind}`);
assert(report.localAgentSpecSummary.promptTransport === "prompt-path", `local agent spec prompt transport ${report.localAgentSpecSummary.promptTransport}`);
assert(report.localAgentSpecSummary.valid === true, "local agent spec should be valid");
assert(report.localAgentSpecSummary.hasWorkspaceInput === true, "local agent spec should pass workspace root");
assert(report.localPlannerSpecSummary.kind === "template", `local planner spec kind ${report.localPlannerSpecSummary.kind}`);
assert(report.localPlannerSpecSummary.promptTransport === "prompt-path", `local planner spec prompt transport ${report.localPlannerSpecSummary.promptTransport}`);
assert(report.localPlannerSpecSummary.valid === true, "local planner spec should be valid");
assert(report.localPlannerSpecSummary.hasSchemaInput === true, "local planner spec should pass schema path");
assert(report.localPlannerSpecPolicy.valid === true, "local planner spec should satisfy standalone policy");
assert(report.localPlannerSpecPolicy.promptTransport === "prompt-path", `local planner spec policy transport ${report.localPlannerSpecPolicy.promptTransport}`);
assert(report.localPlannerSpecPolicy.blockingGaps.length === 0, "local planner spec policy should not report gaps");
assert(report.localPlannerSpecCapability.standaloneReady === true, "local planner spec should be standalone capability ready");
assert(report.localPlannerSpecCapability.requiresExternalModel === false, "local planner spec should not require an external model");
assert(report.localPlannerSpecCapability.roleCoverage.join(",") === "planner,builder,verifier", `local planner spec roles ${report.localPlannerSpecCapability.roleCoverage.join(",")}`);
assert(report.templateSummary.hasReasoningInput === true, "template summary should report reasoning transport");
assert(report.templateSummary.warnings.length === 0, `template warnings ${report.templateSummary.warnings.join(",")}`);
assert(report.codexSummary.kind === "codex", `codex kind ${report.codexSummary.kind}`);
assert(report.codexSummary.promptTransport === "argument", `codex prompt transport ${report.codexSummary.promptTransport}`);
assert(report.codexSummary.valid === true, "codex fallback should be valid");
assert(report.codexSummary.hasReportOutput === true, "codex summary should report fixed report output transport");
assert(report.codexSummary.hasModelInput === true, "codex summary should report fixed model transport");
assert(report.codexSummary.hasReasoningInput === true, "codex summary should report fixed reasoning transport");
assert(report.invalidSummary.kind === "template", `invalid kind ${report.invalidSummary.kind}`);
assert(report.invalidSummary.promptTransport === "missing", `invalid transport ${report.invalidSummary.promptTransport}`);
assert(report.invalidSummary.valid === false, "promptless template should be invalid");
assert(
  report.invalidValidationMessage === "agent-backend-template-missing-prompt-input",
  `invalid validation ${report.invalidValidationMessage}`,
);
assert(report.missingReportSummary.valid === false, "reportless template should be invalid");
assert(report.missingReportSummary.promptTransport === "prompt-path", `missing report transport ${report.missingReportSummary.promptTransport}`);
assert(
  report.missingReportValidationMessage === "agent-backend-template-missing-report-output",
  `missing report validation ${report.missingReportValidationMessage}`,
);
assert(report.warningSummary.valid === true, "template with optional transport warnings should stay valid");
assert(report.warningSummary.promptTransport === "inline-prompt", `warning transport ${report.warningSummary.promptTransport}`);
assert(report.warningSummary.hasSchemaInput === false, "warning summary should expose missing schema transport");
assert(report.warningSummary.hasWorkspaceInput === false, "warning summary should expose missing workspace transport");
assert(report.warningSummary.hasModelInput === false, "warning summary should expose missing model transport");
assert(report.warningSummary.hasReasoningInput === false, "warning summary should expose missing reasoning transport");
assert(
  report.warningSummary.warnings.includes("agent-backend-template-missing-schema-path"),
  `warning summary missing schema warning ${report.warningSummary.warnings.join(",")}`,
);
assert(
  report.warningSummary.warnings.includes("agent-backend-template-missing-workspace-root"),
  `warning summary missing workspace warning ${report.warningSummary.warnings.join(",")}`,
);
assert(
  report.warningSummary.warnings.includes("agent-backend-template-missing-model"),
  `warning summary missing model warning ${report.warningSummary.warnings.join(",")}`,
);
assert(
  report.warningSummary.warnings.includes("agent-backend-template-missing-reasoning"),
  `warning summary missing reasoning warning ${report.warningSummary.warnings.join(",")}`,
);
assert(report.standaloneTemplateValidationMessage === "", `standalone template validation ${report.standaloneTemplateValidationMessage}`);
assert(
  report.standaloneCodexValidationMessage === "agent-backend-policy-disallows-codex-fallback",
  `standalone Codex validation ${report.standaloneCodexValidationMessage}`,
);
assert(report.standaloneTemplateValid === true, "template backend should satisfy standalone policy");
assert(report.standaloneCodexValid === false, "Codex fallback should not satisfy standalone policy");
assert(
  report.strictPromptPathValidationMessage === "agent-backend-policy-requires-prompt-path",
  `strict prompt-path validation ${report.strictPromptPathValidationMessage}`,
);
assert(report.standaloneTemplatePolicy.policyName === "standalone", `template policy ${report.standaloneTemplatePolicy.policyName}`);
assert(report.standaloneTemplatePolicy.backendKind === "template", `template policy backend ${report.standaloneTemplatePolicy.backendKind}`);
assert(report.standaloneTemplatePolicy.promptTransport === "prompt-path+inline", `template policy transport ${report.standaloneTemplatePolicy.promptTransport}`);
assert(report.standaloneTemplatePolicy.valid === true, "template policy summary should be valid");
assert(report.standaloneTemplatePolicy.allowCodexFallback === false, "standalone policy should disallow Codex fallback");
assert(report.standaloneTemplatePolicy.requirePromptPath === true, "standalone policy should require prompt path");
assert(report.standaloneTemplatePolicy.requireSchemaInput === true, "standalone policy should require schema path");
assert(report.standaloneTemplatePolicy.requireWorkspaceInput === true, "standalone policy should require workspace root");
assert(report.standaloneTemplatePolicy.validationMessages.length === 0, "valid standalone template should not report validation messages");
assert(report.standaloneTemplatePolicy.blockingGaps.length === 0, "valid standalone template should not report blocking gaps");
assert(report.standaloneTemplatePolicy.requiredClosure.length === 0, "valid standalone template should not report closure steps");
assert(report.standaloneTemplatePolicy.missingPlaceholders.length === 0, "valid standalone template should not report missing placeholders");
assert(
  report.standaloneTemplatePolicy.recommendedTemplate.includes("{agent_bin}"),
  `template policy recommended template ${report.standaloneTemplatePolicy.recommendedTemplate.join(" ")}`,
);
assert(
  report.standaloneTemplatePolicy.recommendedTemplate.includes("{workspace_root}"),
  `template policy recommended template ${report.standaloneTemplatePolicy.recommendedTemplate.join(" ")}`,
);
assert(report.standaloneCodexPolicy.valid === false, "Codex policy summary should be invalid");
assert(
  report.standaloneCodexPolicy.validationMessage === "agent-backend-policy-disallows-codex-fallback",
  `Codex policy summary ${report.standaloneCodexPolicy.validationMessage}`,
);
assert(
  report.standaloneCodexPolicy.validationMessages.includes("agent-backend-policy-disallows-codex-fallback"),
  `Codex policy validation messages ${report.standaloneCodexPolicy.validationMessages.join(",")}`,
);
assert(
  report.standaloneCodexPolicy.blockingGaps.includes("backend policy requires a configured non-Codex command template"),
  `Codex policy gaps ${report.standaloneCodexPolicy.blockingGaps.join(",")}`,
);
assert(
  report.standaloneCodexPolicy.requiredClosure.includes("Set CLASP_LOOP_AGENT_COMMAND_JSON or CLASP_MANAGER_PLANNER_AGENT_COMMAND_JSON to a non-Codex backend template."),
  `Codex policy closure ${report.standaloneCodexPolicy.requiredClosure.join(",")}`,
);
assert(
  report.standaloneCodexPolicy.requiredClosure.includes("Use agentBackendStandaloneRecommendedTemplate as the minimum command shape for standalone agents."),
  `Codex policy closure ${report.standaloneCodexPolicy.requiredClosure.join(",")}`,
);
assert(
  report.standaloneCodexPolicy.missingPlaceholders.includes("{prompt_path}"),
  `Codex policy missing placeholders ${report.standaloneCodexPolicy.missingPlaceholders.join(",")}`,
);
assert(
  report.standaloneCodexPolicy.missingPlaceholders.includes("{workspace_root}"),
  `Codex policy missing placeholders ${report.standaloneCodexPolicy.missingPlaceholders.join(",")}`,
);
assert(
  report.standaloneCodexPolicy.recommendedTemplate.includes("{prompt_path}"),
  `Codex policy recommended template ${report.standaloneCodexPolicy.recommendedTemplate.join(" ")}`,
);
assert(
  report.strictWarningPolicy.validationMessages.includes("agent-backend-policy-requires-prompt-path"),
  `strict warning policy messages ${report.strictWarningPolicy.validationMessages.join(",")}`,
);
assert(
  report.strictWarningPolicy.validationMessages.includes("agent-backend-policy-requires-schema-path"),
  `strict warning policy messages ${report.strictWarningPolicy.validationMessages.join(",")}`,
);
assert(
  report.strictWarningPolicy.validationMessages.includes("agent-backend-policy-requires-workspace-root"),
  `strict warning policy messages ${report.strictWarningPolicy.validationMessages.join(",")}`,
);
assert(
  report.strictWarningPolicy.blockingGaps.includes("backend policy requires schema transport through {schema_path}"),
  `strict warning policy gaps ${report.strictWarningPolicy.blockingGaps.join(",")}`,
);
assert(
  report.strictWarningPolicy.requiredClosure.includes("Add {workspace_root} to the backend command template."),
  `strict warning policy closure ${report.strictWarningPolicy.requiredClosure.join(",")}`,
);
assert(report.standaloneTemplateCapability.profileName === "local-clasp", `template capability profile ${report.standaloneTemplateCapability.profileName}`);
assert(report.standaloneTemplateCapability.backendKind === "template", `template capability backend ${report.standaloneTemplateCapability.backendKind}`);
assert(report.standaloneTemplateCapability.promptTransport === "prompt-path+inline", `template capability transport ${report.standaloneTemplateCapability.promptTransport}`);
assert(report.standaloneTemplateCapability.standaloneReady === true, "local Clasp backend should be standalone capability ready");
assert(report.standaloneTemplateCapability.roleCoverage.join(",") === "planner,builder,verifier", `template capability roles ${report.standaloneTemplateCapability.roleCoverage.join(",")}`);
assert(report.standaloneTemplateCapability.supportsWorkspaceEdits === true, "local Clasp backend should support workspace edits");
assert(report.standaloneTemplateCapability.supportsChildTaskPlanning === true, "local Clasp backend should support child task planning");
assert(report.standaloneTemplateCapability.supportsStructuredReports === true, "local Clasp backend should support structured reports");
assert(report.standaloneTemplateCapability.requiresExternalModel === false, "local Clasp backend should not require an external model");
assert(report.standaloneTemplateCapability.validationMessages.length === 0, "local Clasp capability should not report validation messages");
assert(report.standaloneTemplateCapability.blockingGaps.length === 0, "local Clasp capability should not report blocking gaps");
assert(report.standaloneCodexCapability.profileName === "codex", `Codex capability profile ${report.standaloneCodexCapability.profileName}`);
assert(report.standaloneCodexCapability.requiresExternalModel === true, "Codex capability should report its external model dependency");
assert(report.standaloneCodexCapability.standaloneReady === false, "Codex fallback should not be standalone capability ready under standalone policy");
assert(
  report.standaloneCodexCapability.validationMessages.includes("agent-backend-policy-disallows-codex-fallback"),
  `Codex capability messages ${report.standaloneCodexCapability.validationMessages.join(",")}`,
);
assert(report.builderVerifierCapability.profileName === "builder-verifier", `builder/verifier profile ${report.builderVerifierCapability.profileName}`);
assert(report.builderVerifierCapability.standaloneReady === false, "builder/verifier-only backend should not be standalone swarm ready");
assert(report.builderVerifierCapability.roleCoverage.join(",") === "builder,verifier", `builder/verifier roles ${report.builderVerifierCapability.roleCoverage.join(",")}`);
assert(
  report.builderVerifierCapability.validationMessages.includes("agent-backend-capability-missing-planner-role"),
  `builder/verifier capability messages ${report.builderVerifierCapability.validationMessages.join(",")}`,
);
assert(
  report.builderVerifierCapability.validationMessages.includes("agent-backend-capability-missing-child-task-planning"),
  `builder/verifier capability messages ${report.builderVerifierCapability.validationMessages.join(",")}`,
);
assert(
  report.builderVerifierCapability.blockingGaps.includes("backend capability profile cannot serve planner tasks"),
  `builder/verifier capability gaps ${report.builderVerifierCapability.blockingGaps.join(",")}`,
);
NODE

  local_routing_output="$test_root/local-routing.txt"
  timeout "$timeout_secs" "$claspc_bin" run "$project_root/examples/swarm-native/LocalRoutingHarness.clasp" >"$local_routing_output"
  if [[ "$(cat "$local_routing_output")" != "local-routing-ok" ]]; then
    printf 'local routing harness failed: %s\n' "$(cat "$local_routing_output")" >&2
    exit 1
  fi
fi

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
grep -F 'AgentCommandTemplateHarness.clasp' "$project_root/scripts/test-agent-command-template.sh" >/dev/null
grep -F 'CLASP_LOOP_AGENT_COMMAND_JSON' "$project_root/examples/swarm-native/FeedbackLoop.clasp" >/dev/null
grep -F 'FeedbackLoopTemplateHarness.clasp' "$project_root/scripts/test-agent-command-template.sh" >/dev/null
grep -F '{prompt_path}' "$project_root/examples/swarm-native/AgentBackend.clasp" >/dev/null
grep -F 'local Clasp builder backend completed' "$project_root/examples/swarm-native/LocalAgent.clasp" >/dev/null
grep -F 'import GoalManagerAgentBackendConfig' "$project_root/examples/swarm-native/GoalManagerConfig.clasp" >/dev/null
grep -F 'CLASP_MANAGER_PLANNER_AGENT_COMMAND_JSON' "$project_root/examples/swarm-native/GoalManagerAgentBackendConfig.clasp" >/dev/null
grep -F 'plannerAgentCommandArgs' "$project_root/examples/swarm-native/GoalManagerBootstrapPlanner.clasp" >/dev/null
grep -F 'CLASP_LOOP_AGENT_COMMAND_JSON' "$project_root/examples/swarm-native/GoalManagerServiceMain.clasp" >/dev/null

if [[ "$run_feedback_template" == "1" ]]; then
  feedback_harness_bin="$test_root/agent-command-template-harness-bin"
  env RUSTC=/definitely-missing-rustc CLASP_PROJECT_ROOT="$project_root" \
    timeout "$timeout_secs" "$claspc_bin" compile "$project_root/examples/feedback-loop/AgentCommandTemplateHarness.clasp" \
      -o "$feedback_harness_bin" >/dev/null

  mkdir -p "$workspace_root"
  CLASP_LOOP_AGENT_BIN_JSON="$agent_bin_json" \
    CLASP_LOOP_AGENT_COMMAND_JSON="$agent_command_json" \
    CLASP_LOOP_TASK_FILE_JSON="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$task_file")" \
    CLASP_LOOP_WORKSPACE_JSON="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$workspace_root")" \
    CLASP_LOOP_MAX_ATTEMPTS_JSON='1' \
    CLASP_TEST_AGENT_LOG="$agent_log" \
    timeout "$timeout_secs" "$feedback_harness_bin" "$state_root" >"$output_path"

  CLASP_LOOP_COMMAND=status \
    timeout "$timeout_secs" "$feedback_harness_bin" "$state_root" >"$status_path"

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
  native_feedback_harness_bin="$test_root/feedback-loop-template-harness-bin"
  local_agent_bin="$test_root/local-agent-bin"
  env RUSTC=/definitely-missing-rustc CLASP_PROJECT_ROOT="$project_root" \
    timeout "$timeout_secs" "$claspc_bin" compile "$project_root/examples/swarm-native/FeedbackLoopTemplateHarness.clasp" \
      -o "$native_feedback_harness_bin" >/dev/null
  env RUSTC=/definitely-missing-rustc CLASP_PROJECT_ROOT="$project_root" \
    timeout "$timeout_secs" "$claspc_bin" compile "$project_root/examples/swarm-native/LocalAgent.clasp" \
      -o "$local_agent_bin" >/dev/null
  local_agent_bin_json="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$local_agent_bin")"
  local_agent_binary_command_json="$(
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
  "{workspace_root}"
]));
NODE
  )"

  mkdir -p "$native_workspace_root"
  CLASP_LOOP_AGENT_BIN_JSON="$agent_bin_json" \
    CLASP_LOOP_AGENT_COMMAND_JSON="$native_agent_command_json" \
    CLASP_LOOP_TASK_FILE_JSON="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$task_file")" \
    CLASP_LOOP_WORKSPACE_JSON="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$native_workspace_root")" \
    CLASP_LOOP_MAX_ATTEMPTS_JSON='1' \
    CLASP_TEST_AGENT_LOG="$native_agent_log" \
    timeout "$timeout_secs" "$native_feedback_harness_bin" "$native_state_root" >"$native_output_path"

  CLASP_LOOP_AGENT_BIN_JSON="$agent_bin_json" \
    CLASP_LOOP_AGENT_COMMAND_JSON="$native_agent_command_json" \
    CLASP_LOOP_WORKSPACE_JSON="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$native_workspace_root")" \
    CLASP_LOOP_COMMAND=status \
    timeout "$timeout_secs" "$native_feedback_harness_bin" "$native_state_root" >"$native_status_path"

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
assert(output.agentBackend?.kind === "template", `native backend kind ${output.agentBackend?.kind}`);
assert(output.agentBackend?.promptTransport === "inline-prompt", `native backend prompt transport ${output.agentBackend?.promptTransport}`);
assert(output.agentBackend?.valid === true, "native backend template should be valid");
assert(output.agentBackendCapability?.profileName === "local-clasp", `native capability profile ${output.agentBackendCapability?.profileName}`);
assert(output.agentBackendCapability?.supportsBuilderRole === true, "native capability summary should include builder support");
assert(output.agentBackendCapability?.supportsVerifierRole === true, "native capability summary should include verifier support");
assert(output.agentBackendCapability?.requiresExternalModel === false, "native capability summary should report no external-model requirement");
assert(output.objectiveProjectedStatus === "completed", `native projected ${output.objectiveProjectedStatus}`);
assert(output.taskCount === 2, `native task count ${output.taskCount}`);
assert(output.approvalCount === 1, `native approval count ${output.approvalCount}`);
assert(output.mergeGateSatisfied === true, "native merge gate should be satisfied");
assert(status.state?.phase === "completed", `native status phase ${status.state?.phase}`);
assert(status.state?.verdict === "pass" && status.state?.final === true, "native status should persist a passing final status");
assert(status.agentBackend?.kind === "template", `native status backend kind ${status.agentBackend?.kind}`);
assert(status.agentBackend?.promptTransport === "inline-prompt", `native status backend prompt transport ${status.agentBackend?.promptTransport}`);
assert(status.agentBackendCapability?.profileName === "local-clasp", `native status capability profile ${status.agentBackendCapability?.profileName}`);
assert(status.agentBackendCapability?.roleCoverage?.includes("planner"), "native status capability summary should include planner coverage");
assert(artifact === "generic-agent-template-ok", "native generic builder should update the workspace");
assert(invocations.map((entry) => entry.role).join(",") === "builder,verifier", "native generic agent should run builder then verifier");
  for (const invocation of invocations) {
    assert(!invocation.reportPath.includes("codex"), "native generic template should not need Codex-named report paths");
    assert(invocation.promptPath === "", "native generic template should receive an inline prompt");
    assert(invocation.promptHasTaskFileContent === true, "native generic template should receive inlined task file content");
    assert(invocation.promptHasTaskText === true, "native generic template should receive the task file text");
  }
NODE

  invalid_agent_command_json="$(
    node - <<'NODE'
process.stdout.write(JSON.stringify([
  "{agent_bin}",
  "--role",
  "{role}"
]));
NODE
)"
  CLASP_LOOP_AGENT_BIN_JSON="$agent_bin_json" \
    CLASP_LOOP_AGENT_COMMAND_JSON="$invalid_agent_command_json" \
    CLASP_LOOP_TASK_FILE_JSON="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$task_file")" \
    CLASP_LOOP_WORKSPACE_JSON="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$native_workspace_root")" \
    CLASP_LOOP_MAX_ATTEMPTS_JSON='1' \
    timeout "$timeout_secs" "$native_feedback_harness_bin" "$test_root/native-invalid-template-state" >"$native_invalid_template_output_path"

  native_invalid_template_output="$(cat "$native_invalid_template_output_path")"
  if [[ "$native_invalid_template_output" != *"config-error:agent-backend-template-missing-prompt-input"* ]]; then
    printf 'promptless agent template was not rejected: %s\n' "$native_invalid_template_output" >&2
    exit 72
  fi
  if [[ "$native_invalid_template_output" != *"backendConfigRepair=agent-backend"* ]]; then
    printf 'promptless agent template did not include backend repair action: %s\n' "$native_invalid_template_output" >&2
    exit 72
  fi
  if [[ "$native_invalid_template_output" != *"Agent backend policy repair:"* ]]; then
    printf 'promptless agent template did not include backend policy repair context: %s\n' "$native_invalid_template_output" >&2
    exit 72
  fi
  if [[ "$native_invalid_template_output" != *"policyRequiredClosure="* ]]; then
    printf 'promptless agent template did not include backend closure steps: %s\n' "$native_invalid_template_output" >&2
    exit 72
  fi
  if [[ "$native_invalid_template_output" != *"Agent backend capability repair:"* ]]; then
    printf 'promptless agent template did not include backend capability repair context: %s\n' "$native_invalid_template_output" >&2
    exit 72
  fi

  mkdir -p "$local_agent_workspace_root"
  CLASP_LOOP_AGENT_BIN_JSON="$local_agent_bin_json" \
    CLASP_LOOP_AGENT_COMMAND_JSON="$local_agent_binary_command_json" \
    CLASP_LOOP_TASK_FILE_JSON="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$task_file")" \
    CLASP_LOOP_WORKSPACE_JSON="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$local_agent_workspace_root")" \
    CLASP_LOOP_MAX_ATTEMPTS_JSON='2' \
    timeout "$timeout_secs" "$native_feedback_harness_bin" "$local_agent_state_root" >"$local_agent_output_path"

  CLASP_LOOP_AGENT_BIN_JSON="$local_agent_bin_json" \
    CLASP_LOOP_AGENT_COMMAND_JSON="$local_agent_binary_command_json" \
    CLASP_LOOP_WORKSPACE_JSON="$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$local_agent_workspace_root")" \
    CLASP_LOOP_COMMAND=status \
    timeout "$timeout_secs" "$native_feedback_harness_bin" "$local_agent_state_root" >"$local_agent_status_path"

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
assert(output.agentBackend?.kind === "template", `local backend kind ${output.agentBackend?.kind}`);
assert(output.agentBackend?.promptTransport === "prompt-path", `local backend prompt transport ${output.agentBackend?.promptTransport}`);
assert(output.agentBackend?.valid === true, "local backend template should be valid");
assert(output.agentBackendCapability?.profileName === "local-clasp", `local capability profile ${output.agentBackendCapability?.profileName}`);
assert(output.agentBackendCapability?.standaloneReady === true, "local capability summary should be standalone ready");
assert(output.objectiveProjectedStatus === "completed", `local projected ${output.objectiveProjectedStatus}`);
assert(status.state?.phase === "completed", `local status phase ${status.state?.phase}`);
assert(status.agentBackend?.kind === "template", `local status backend kind ${status.agentBackend?.kind}`);
assert(status.agentBackend?.promptTransport === "prompt-path", `local status backend prompt transport ${status.agentBackend?.promptTransport}`);
assert(status.agentBackendPolicy?.recommendedTemplate?.includes("{prompt_path}"), "local status should expose backend policy recommended template");
assert(status.agentBackendCapability?.profileName === "local-clasp", `local status capability profile ${status.agentBackendCapability?.profileName}`);
assert(status.agentBackendCapability?.supportsChildTaskPlanning === true, "local status capability summary should include child-task planning support");
assert(status.previousVerifierFeedback?.present === true, "local status should persist previous verifier feedback");
assert(workspaceText === "fixed-after-feedback\n", "local Clasp builder should consume verifier feedback");
assert(secondBuilder.feedback?.summary === "local Clasp builder backend completed", "second builder report should come from LocalAgent.clasp");
assert(secondBuilder.tests_run?.includes("clasp-local-agent-context-pack"), "local builder should record context-pack coverage");
assert(secondBuilder.tests_run?.includes("clasp-local-agent-task-file-prompt"), "local builder should record task-file prompt coverage");
assert(secondBuilder.tests_run?.includes("clasp-local-agent-backend-policy-repair"), "local builder should record backend policy repair coverage");
assert(
  secondBuilder.feedback?.ergonomics?.includes("local builder consumed the native swarm context pack"),
  "local builder feedback should mention native context pack consumption",
);
assert(
  secondBuilder.feedback?.ergonomics?.includes("local builder received the task file content in its prompt"),
  "local builder feedback should mention task file prompt content",
);
assert(
  secondBuilder.feedback?.ergonomics?.includes("local builder consumed backend policy repair context"),
  "local builder feedback should mention backend policy repair context",
);
assert(firstVerifier.verdict === "fail", `first local verifier verdict ${firstVerifier.verdict}`);
assert(firstVerifier.tests_run?.includes("clasp-local-agent-context-pack"), "first local verifier should record context-pack coverage");
assert(firstVerifier.tests_run?.includes("clasp-local-agent-task-file-prompt"), "first local verifier should record task-file prompt coverage");
assert(firstVerifier.tests_run?.includes("clasp-local-agent-backend-policy-repair"), "first local verifier should record backend policy repair coverage");
assert(secondVerifier.verdict === "pass", `second local verifier verdict ${secondVerifier.verdict}`);
assert(secondVerifier.tests_run?.includes("clasp-local-agent-context-pack"), "second local verifier should record context-pack coverage");
assert(secondVerifier.tests_run?.includes("clasp-local-agent-task-file-prompt"), "second local verifier should record task-file prompt coverage");
assert(secondVerifier.tests_run?.includes("clasp-local-agent-backend-policy-repair"), "second local verifier should record backend policy repair coverage");
assert(secondBuilderPrompt.includes("Verifier feedback from the previous attempt:"), "second builder prompt should be persisted for prompt-path agents");
assert(secondBuilderPrompt.includes("force-close-category"), "second builder prompt should include persisted verifier feedback");
assert(secondBuilderPrompt.includes("Agent backend policy repair:"), "second builder prompt should include backend policy repair context");
assert(secondBuilderPrompt.includes("policyMessages="), "second builder prompt should include all backend policy messages");
assert(secondBuilderPrompt.includes("policyRecommendedTemplate="), "second builder prompt should include backend policy recommended template");
assert(secondBuilderPrompt.includes("Agent backend capability repair:"), "second builder prompt should include backend capability repair context");
assert(secondBuilderPrompt.includes("capabilityMessages="), "second builder prompt should include backend capability messages");
assert(secondBuilderPrompt.includes("capabilitySupports=planner:"), "second builder prompt should include backend capability support flags");
assert(secondBuilderPrompt.includes("Swarm context pack:"), "second builder prompt should include native context pack evidence");
assert(secondBuilderPrompt.includes("artifact search matches:"), "second builder prompt should include artifact search evidence");
assert(secondBuilderPrompt.includes("semantic index artifact matches:"), "second builder prompt should include semantic index evidence");
assert(secondBuilderPrompt.includes("semantic index edit files:"), "second builder prompt should include semantic edit-file evidence");
assert(secondBuilderPrompt.includes("semantic index surface ids:"), "second builder prompt should include semantic surface evidence");
assert(secondBuilderPrompt.includes("benchmark history matches:"), "second builder prompt should include benchmark history context");
assert(secondBuilderPrompt.includes("dependency task ids:"), "second builder prompt should include dependency id context");
assert(secondBuilderPrompt.includes("dependency task statuses:"), "second builder prompt should include dependency status context");
assert(secondBuilderPrompt.includes("dependency task ready:"), "second builder prompt should include dependency ready context");
assert(secondBuilderPrompt.includes("task: builder-2"), "second builder prompt should identify the builder task context");
assert(secondBuilderPrompt.includes("verifier-feedback"), "second builder prompt should include persisted verifier feedback memory");
assert(secondBuilderPrompt.includes("Task file content:"), "second builder prompt should include inlined task file content");
assert(
  secondBuilderPrompt.includes("Prove a generic non-Codex agent command template can run the Clasp feedback loop."),
  "second builder prompt should include the task file text",
);
assert(secondVerifierPrompt.includes("verifier subagent"), "second verifier prompt should be persisted for prompt-path agents");
assert(secondVerifierPrompt.includes("Agent backend policy repair:"), "second verifier prompt should include backend policy repair context");
assert(secondVerifierPrompt.includes("policyMessages="), "second verifier prompt should include all backend policy messages");
assert(secondVerifierPrompt.includes("policyRecommendedTemplate="), "second verifier prompt should include backend policy recommended template");
assert(secondVerifierPrompt.includes("Agent backend capability repair:"), "second verifier prompt should include backend capability repair context");
assert(secondVerifierPrompt.includes("capabilityMessages="), "second verifier prompt should include backend capability messages");
assert(secondVerifierPrompt.includes("capabilitySupports=planner:"), "second verifier prompt should include backend capability support flags");
assert(secondVerifierPrompt.includes("Swarm context pack:"), "second verifier prompt should include native context pack evidence");
assert(secondVerifierPrompt.includes("artifact search matches:"), "second verifier prompt should include artifact search evidence");
assert(secondVerifierPrompt.includes("semantic index artifact matches:"), "second verifier prompt should include semantic index evidence");
assert(secondVerifierPrompt.includes("semantic index edit files:"), "second verifier prompt should include semantic edit-file evidence");
assert(secondVerifierPrompt.includes("semantic index surface ids:"), "second verifier prompt should include semantic surface evidence");
assert(secondVerifierPrompt.includes("benchmark history matches:"), "second verifier prompt should include benchmark history context");
assert(secondVerifierPrompt.includes("dependency task ids:"), "second verifier prompt should include dependency id context");
assert(secondVerifierPrompt.includes("dependency task statuses:"), "second verifier prompt should include dependency status context");
assert(secondVerifierPrompt.includes("dependency task ready:"), "second verifier prompt should include dependency ready context");
assert(secondVerifierPrompt.includes("builder-2"), "second verifier prompt should include builder dependency id");
assert(secondVerifierPrompt.includes("task: verifier-2"), "second verifier prompt should identify the verifier task context");
assert(secondVerifierPrompt.includes("run trace:"), "second verifier prompt should include run trace context");
assert(secondVerifierPrompt.includes("Task file content:"), "second verifier prompt should include inlined task file content");
assert(
  secondVerifierPrompt.includes("Prove a generic non-Codex agent command template can run the Clasp feedback loop."),
  "second verifier prompt should include the task file text",
);
assert(
  secondVerifier.capability_statuses?.some((entry) => entry.name === "clasp_native_agent_backend" && entry.status === "pass"),
  "local verifier should prove the Clasp-native agent backend capability",
);
assert(
  secondVerifier.capability_statuses?.some((entry) =>
    entry.evidence?.includes("local Clasp agent consumed native builder and verifier context packs")
  ),
  "local verifier should report native context-pack consumption evidence",
);
assert(
  secondVerifier.capability_statuses?.some((entry) =>
    entry.evidence?.includes("local Clasp agent received task file content without reading a separate task file")
  ),
  "local verifier should report task-file prompt evidence",
);
assert(
  secondVerifier.capability_statuses?.some((entry) =>
    entry.evidence?.includes("local Clasp agent consumed backend policy repair context")
  ),
  "local verifier should report backend policy repair evidence",
);
NODE

  mkdir -p "$local_agent_route_root"
  cat >"$local_agent_route_root/builder-1.prompt.md" <<'EOF'
You are the builder subagent.
Swarm context pack:
task: builder-1 status=ready ready=true attempts=0
artifact search matches:
- none
semantic index artifact matches:
- none
semantic index edit files:
src/Compiler/Checker.clasp
semantic index surface ids:
compiler:checker
Task file content:
Use the supplied native context evidence to make one bounded self-improvement change.
EOF

  cat >"$local_agent_route_root/verifier-1.prompt.md" <<'EOF'
You are the verifier subagent.
Swarm context pack:
task: verifier-1 status=ready ready=true attempts=0
semantic index edit files:
src/Compiler/Checker.clasp
semantic index surface ids:
compiler:checker
run trace:
- builder-1 completed
Task file content:
Use the supplied native context evidence to make one bounded self-improvement change.
EOF

  cat >"$local_agent_route_root/builder-2.prompt.md" <<'EOF'
You are the builder subagent.
Swarm context pack:
task: builder-2 status=ready ready=true attempts=1
artifact search matches:
- verifier feedback exists
semantic index edit files:
src/Compiler/Checker.clasp
semantic index surface ids:
compiler:checker
Verifier feedback from the previous attempt:
force-close-category
Task file content:
Use the supplied native context evidence to make one bounded self-improvement change.
EOF

  cat >"$local_agent_route_root/verifier-2.prompt.md" <<'EOF'
You are the verifier subagent.
Swarm context pack:
task: verifier-2 status=ready ready=true attempts=1
semantic index edit files:
src/Compiler/Checker.clasp
semantic index surface ids:
compiler:checker
run trace:
- builder-2 completed
Task file content:
Use the supplied native context evidence to make one bounded self-improvement change.
EOF

  timeout "$timeout_secs" "$local_agent_bin" \
    --role builder \
    --report "$local_agent_route_root/builder-1.json" \
    --prompt-path "$local_agent_route_root/builder-1.prompt.md" \
    --workspace "$local_agent_route_workspace" >/dev/null
  timeout "$timeout_secs" "$local_agent_bin" \
    --role verifier \
    --report "$local_agent_route_root/verifier-1.json" \
    --prompt-path "$local_agent_route_root/verifier-1.prompt.md" \
    --workspace "$local_agent_route_workspace" >/dev/null
  timeout "$timeout_secs" "$local_agent_bin" \
    --role builder \
    --report "$local_agent_route_root/builder-2.json" \
    --prompt-path "$local_agent_route_root/builder-2.prompt.md" \
    --workspace "$local_agent_route_workspace" >/dev/null
  timeout "$timeout_secs" "$local_agent_bin" \
    --role verifier \
    --report "$local_agent_route_root/verifier-2.json" \
    --prompt-path "$local_agent_route_root/verifier-2.prompt.md" \
    --workspace "$local_agent_route_workspace" >/dev/null

  node - "$local_agent_route_workspace/workspace.txt" "$local_agent_route_workspace/notes/local-agent-route.txt" "$local_agent_route_root/builder-2.json" "$local_agent_route_root/verifier-1.json" "$local_agent_route_root/verifier-2.json" <<'NODE'
const fs = require("node:fs");
const [workspacePath, routePath, builderPath, verifier1Path, verifier2Path] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function readJson(path) {
  return JSON.parse(fs.readFileSync(path, "utf8"));
}

const workspaceText = fs.readFileSync(workspacePath, "utf8");
const routeText = fs.readFileSync(routePath, "utf8");
const builder = readJson(builderPath);
const verifier1 = readJson(verifier1Path);
const verifier2 = readJson(verifier2Path);

assert(workspaceText === "iteration-speed-fixed-after-feedback\n", "routed local agent should write iteration-speed completion content");
assert(routeText === "iteration-speed\n", "routed local agent should persist the task route");
assert(builder.files_touched?.includes("notes/local-agent-route.txt"), "routed builder should report the route artifact");
assert(builder.tests_run?.includes("clasp-local-agent-task-routing"), "routed builder should record task-routing coverage");
assert(
  builder.feedback?.ergonomics?.includes("local builder routed task kind: iteration-speed"),
  "routed builder feedback should include task kind",
);
assert(verifier1.verdict === "fail", `first routed verifier verdict ${verifier1.verdict}`);
assert(verifier1.tests_run?.includes("clasp-local-agent-task-routing"), "first routed verifier should record task-routing coverage");
assert(verifier1.summary.includes("iteration-speed"), `first routed verifier summary ${verifier1.summary}`);
assert(verifier2.verdict === "pass", `second routed verifier verdict ${verifier2.verdict}`);
assert(verifier2.tests_run?.includes("clasp-local-agent-task-routing"), "second routed verifier should record task-routing coverage");
assert(verifier2.summary.includes("iteration-speed"), `second routed verifier summary ${verifier2.summary}`);
assert(
  verifier2.capability_statuses?.some((entry) =>
    entry.evidence?.includes("local Clasp agent completed routed task kind: iteration-speed")
  ),
  "routed verifier should prove the completed task kind",
);
NODE

  mkdir -p "$local_agent_dependency_root"
  cat >"$local_agent_dependency_root/builder.prompt.md" <<'EOF'
You are the builder subagent.
Swarm context pack:
task: builder-1 status=ready ready=true attempts=1
dependency task ids:
- iteration-speed-loop
- semantic-context-routing
dependency task statuses:
- completed
- completed
dependency task ready:
- false
- false
artifact search matches:
- verifier feedback exists
Verifier feedback from the previous attempt:
force-close-category
Task file content:
Improve standalone-swarm readiness after the prerequisite tasks have passed.
EOF

  cat >"$local_agent_dependency_root/verifier.prompt.md" <<'EOF'
You are the verifier subagent.
Swarm context pack:
task: verifier-1 status=ready ready=true attempts=1
dependency task ids:
- iteration-speed-loop
- semantic-context-routing
dependency task statuses:
- completed
- completed
dependency task ready:
- false
- false
run trace:
- builder-1 completed
Task file content:
Improve standalone-swarm readiness after the prerequisite tasks have passed.
EOF

  timeout "$timeout_secs" "$local_agent_bin" \
    --role builder \
    --report "$local_agent_dependency_root/builder.json" \
    --prompt-path "$local_agent_dependency_root/builder.prompt.md" \
    --workspace "$local_agent_dependency_workspace" >/dev/null
  timeout "$timeout_secs" "$local_agent_bin" \
    --role verifier \
    --report "$local_agent_dependency_root/verifier.json" \
    --prompt-path "$local_agent_dependency_root/verifier.prompt.md" \
    --workspace "$local_agent_dependency_workspace" >/dev/null

  node - "$local_agent_dependency_workspace/workspace.txt" "$local_agent_dependency_workspace/notes/local-agent-route.txt" "$local_agent_dependency_root/builder.json" "$local_agent_dependency_root/verifier.json" <<'NODE'
const fs = require("node:fs");
const [workspacePath, routePath, builderPath, verifierPath] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function readJson(path) {
  return JSON.parse(fs.readFileSync(path, "utf8"));
}

const workspaceText = fs.readFileSync(workspacePath, "utf8");
const routeText = fs.readFileSync(routePath, "utf8");
const builder = readJson(builderPath);
const verifier = readJson(verifierPath);

assert(workspaceText === "standalone-swarm-fixed-after-feedback\n", "dependency-aware local agent should write standalone-swarm completion content");
assert(routeText === "standalone-swarm\n", "dependency-aware local agent should persist standalone-swarm route");
assert(builder.tests_run?.includes("clasp-local-agent-dependency-evidence"), "dependency-aware builder should record dependency evidence coverage");
assert(
  builder.feedback?.ergonomics?.includes("local builder consumed dependency completion evidence"),
  "dependency-aware builder feedback should mention dependency evidence",
);
assert(verifier.verdict === "pass", `dependency verifier verdict ${verifier.verdict}`);
assert(verifier.tests_run?.includes("clasp-local-agent-dependency-evidence"), "dependency-aware verifier should record dependency evidence coverage");
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.evidence?.includes("local Clasp agent consumed dependency completion evidence")
  ),
  "dependency-aware verifier should prove dependency evidence consumption",
);
NODE

  mkdir -p "$local_agent_goal_root"
  cat >"$local_agent_goal_root/builder.prompt.md" <<'EOF'
You are the builder subagent.
Swarm context pack:
task: builder-1 status=ready ready=true attempts=1
artifact search matches:
- verifier feedback exists
Verifier feedback from the previous attempt:
force-close-category
Task file content:
Make Clasp the best language for AI agents to code and create agent swarms without Codex-specific control flow.
EOF

  cat >"$local_agent_goal_root/verifier.prompt.md" <<'EOF'
You are the verifier subagent.
Swarm context pack:
task: verifier-1 status=ready ready=true attempts=1
run trace:
- builder-1 completed
Task file content:
Make Clasp the best language for AI agents to code and create agent swarms without Codex-specific control flow.
EOF

  timeout "$timeout_secs" "$local_agent_bin" \
    --role builder \
    --report "$local_agent_goal_root/builder.json" \
    --prompt-path "$local_agent_goal_root/builder.prompt.md" \
    --workspace "$local_agent_goal_workspace" >/dev/null
  timeout "$timeout_secs" "$local_agent_bin" \
    --role verifier \
    --report "$local_agent_goal_root/verifier.json" \
    --prompt-path "$local_agent_goal_root/verifier.prompt.md" \
    --workspace "$local_agent_goal_workspace" >/dev/null

  node - "$local_agent_goal_workspace/workspace.txt" "$local_agent_goal_workspace/notes/local-agent-route.txt" "$local_agent_goal_root/builder.json" "$local_agent_goal_root/verifier.json" <<'NODE'
const fs = require("node:fs");
const [workspacePath, routePath, builderPath, verifierPath] = process.argv.slice(2);

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function readJson(path) {
  return JSON.parse(fs.readFileSync(path, "utf8"));
}

const workspaceText = fs.readFileSync(workspacePath, "utf8");
const routeText = fs.readFileSync(routePath, "utf8");
const builder = readJson(builderPath);
const verifier = readJson(verifierPath);

assert(workspaceText === "standalone-swarm-fixed-after-feedback\n", "AI-agent swarm goal should write standalone-swarm completion content");
assert(routeText === "standalone-swarm\n", "AI-agent swarm goal should persist standalone-swarm route");
assert(builder.tests_run?.includes("clasp-local-agent-task-routing"), "AI-agent swarm builder should record task-routing coverage");
assert(
  builder.feedback?.ergonomics?.includes("local builder routed task kind: standalone-swarm"),
  "AI-agent swarm builder feedback should include standalone-swarm route",
);
assert(verifier.verdict === "pass", `AI-agent swarm verifier verdict ${verifier.verdict}`);
assert(verifier.tests_run?.includes("clasp-local-agent-task-routing"), "AI-agent swarm verifier should record task-routing coverage");
assert(verifier.summary.includes("standalone-swarm"), `AI-agent swarm verifier summary ${verifier.summary}`);
assert(
  verifier.capability_statuses?.some((entry) =>
    entry.evidence?.includes("local Clasp agent completed routed task kind: standalone-swarm")
  ),
  "AI-agent swarm verifier should prove standalone-swarm routing",
);
NODE

  printf 'native-clasp-goal-routing-ok\n'
  printf 'native-clasp-local-agent-template-ok\n'
  printf 'native-provider-neutral-agent-template-ok\n'
fi

printf 'agent-command-template-ok\n'
