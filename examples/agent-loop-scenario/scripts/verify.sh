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

cleanup() {
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root" >&2
  else
    rm -rf "${test_root:-}" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

mkdir -p "$workspace_root/src" "$workspace_root/artifacts"
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
demo_path="$project_root/examples/agent-loop-scenario/Main.clasp"

if grep -F '"bash"' "$demo_path" >/dev/null; then
  fail "agent loop scenario should invoke direct executables, not shell wrappers"
fi

grep -F 'agentReadTextOrEmpty' "$demo_path" >/dev/null
grep -F 'agentWriteTextStatus' "$demo_path" >/dev/null
grep -F 'agentAppendEvent' "$demo_path" >/dev/null
grep -F 'workspaceAppendText' "$project_root/examples/agent-loop-scenario/AgentRuntime.clasp" >/dev/null
grep -F 'run (commandSpec workspaceRoot "."' "$demo_path" >/dev/null
grep -F '"exec"' "$demo_path" >/dev/null
grep -F '"--output-last-message"' "$demo_path" >/dev/null

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
const eventLines = fs
  .readFileSync(path.join(workspaceRoot, "agent-loop-events.jsonl"), "utf8")
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

assert(report.inputText === "alpha task input\n", "input file should be inspected");
assert(report.builder.ok === true, "builder should pass");
assert(report.builder.status === "completed-pass", `unexpected builder status ${report.builder.status}`);
assert(report.builder.exitCode === 0, "builder exit should be zero");
assert(report.builder.stdout.includes('"role":"builder"'), "builder stdout should be captured");
assert(report.builder.stderr === "builder stderr event", "builder stderr should be captured");
assert(report.builder.finalText === "builder final from fake codex\n", "builder final should be captured");

assert(report.verifier.ok === true, "verifier should pass");
assert(report.verifier.status === "completed-pass", `unexpected verifier status ${report.verifier.status}`);
assert(report.verifier.exitCode === 0, "verifier exit should be zero");
assert(report.verifier.stdout.includes('"ok":true'), "verifier stdout should contain structured JSON");
assert(report.verifier.timedOut === false, "verifier should not time out");

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
NODE

printf 'agent-loop-scenario-ok\n'
