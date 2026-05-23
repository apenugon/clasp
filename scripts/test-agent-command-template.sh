#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_AGENT_COMMAND_TEMPLATE_TIMEOUT_SECS:-150}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_AGENT_COMMAND_TEMPLATE_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-agent-command-template.XXXXXX")"
state_root="$test_root/state"
workspace_root="$test_root/workspace"
task_file="$test_root/task.md"
fake_agent="$test_root/generic-agent"
output_path="$test_root/output.txt"
status_path="$test_root/status.json"
agent_log="$test_root/agent-invocations.jsonl"

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

if [[ -z "$role" || -z "$report_path" || -z "$prompt_path" ]]; then
  printf 'missing required generic-agent arguments\n' >&2
  exit 65
fi

prompt="$(cat "$prompt_path")"
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
      printf 'builder prompt was not supplied through prompt_path\n' >&2
      exit 66
    fi
    printf 'generic-agent-template-ok\n' >"$workspace_root/generic-agent.txt"
    cat >"$report_path" <<'JSON'
{"summary":"generic builder completed","files_touched":["generic-agent.txt"],"tests_run":["generic-agent-template"],"residual_risks":[],"feedback":{"summary":"generic builder feedback","ergonomics":["provider-neutral agent command template worked"],"follow_ups":[],"warnings":[]}}
JSON
    ;;
  verifier)
    if [[ "$prompt" != *"verifier subagent"* ]]; then
      printf 'verifier prompt was not supplied through prompt_path\n' >&2
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

grep -F 'CLASP_LOOP_AGENT_COMMAND_JSON' "$project_root/examples/feedback-loop/Main.clasp" >/dev/null
grep -F 'CLASP_LOOP_AGENT_COMMAND_JSON' "$project_root/examples/swarm-native/FeedbackLoop.clasp" >/dev/null
grep -F 'CLASP_MANAGER_PLANNER_AGENT_COMMAND_JSON' "$project_root/examples/swarm-native/GoalManagerConfig.clasp" >/dev/null
grep -F 'plannerAgentCommandArgs' "$project_root/examples/swarm-native/GoalManagerBootstrapPlanner.clasp" >/dev/null
grep -F 'CLASP_LOOP_AGENT_COMMAND_JSON' "$project_root/examples/swarm-native/GoalManagerServiceMain.clasp" >/dev/null

CLASP_LOOP_AGENT_BIN_JSON="$agent_bin_json" \
  CLASP_LOOP_AGENT_COMMAND_JSON="$agent_command_json" \
  timeout "$timeout_secs" "$claspc_bin" --json check "$project_root/examples/feedback-loop/Main.clasp" |
  grep -F '"status":"ok"' >/dev/null

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

printf 'agent-command-template-ok\n'
