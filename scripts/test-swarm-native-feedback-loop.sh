#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
timeout_secs="${CLASP_SWARM_FEEDBACK_LOOP_TIMEOUT_SECS:-180}"

if ! [[ "$timeout_secs" =~ ^[0-9]+$ ]] || (( timeout_secs < 1 )); then
  printf 'CLASP_SWARM_FEEDBACK_LOOP_TIMEOUT_SECS must be a positive integer\n' >&2
  exit 1
fi

mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/test-swarm-native-feedback-loop.XXXXXX")"
test_root_abs="$(cd "$test_root" && pwd -P)"
state_root="$test_root_abs/state"
workspace_root="$test_root_abs/workspace"
task_file="$test_root_abs/task.md"
fake_codex="$test_root_abs/codex"
run_output="$test_root_abs/run-output.json"
status_output="$test_root_abs/status-output.json"
objective_output="$test_root_abs/objective-status.json"
verifier_status_output="$test_root_abs/verifier-status.txt"
approvals_output="$test_root_abs/approvals.json"
tail_output="$test_root_abs/tail.json"
builder_runs_output="$test_root_abs/builder-runs.json"
verifier_runs_output="$test_root_abs/verifier-runs.json"
builder_artifacts_output="$test_root_abs/builder-artifacts.json"
demo_path="$project_root/examples/swarm-native/FeedbackLoop.clasp"

test_xdg_cache_home="${CLASP_TEST_SHARED_XDG_CACHE_HOME:-$tmp_root/clasp-test-xdg-cache}"
if [[ "${CLASP_TEST_ISOLATED_XDG_CACHE:-0}" == "1" ]]; then
  test_xdg_cache_home="$test_root_abs/xdg-cache"
fi
mkdir -p "$test_xdg_cache_home"
export XDG_CACHE_HOME="$test_xdg_cache_home"

cleanup() {
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root_abs" >&2
  else
    rm -rf "$test_root_abs" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

cat >"$task_file" <<'EOF'
Make the native FeedbackLoop fixture converge after verifier feedback.
EOF

cat >"$fake_codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

workspace_root="."
report_path=""
prompt=""

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
    -m|-c|--sandbox|--output-schema)
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
  prompt="$(cat)"
fi

if [[ -z "$report_path" ]]; then
  printf 'missing report path\n' >&2
  exit 1
fi

feedback_path="$(dirname "$report_path")/feedback.json"
builder_policy_path="$(dirname "$report_path")/builder-policy.md"
workspace_path="$workspace_root/workspace.txt"
artifact_path="$workspace_root/notes/child-artifact.txt"

emit_report_payload() {
  mkdir -p "$(dirname "$report_path")"
  printf '%s\n' "$(cat)" >"$report_path"
}

if [[ "$prompt" == *"builder subagent"* ]]; then
  printf '{"phase":"builder-start"}\n'
  printf 'builder-progress\n' >&2
  sleep "${CLASP_TEST_FAKE_CODEX_SLEEP_SECS:-0}"
  content="first-attempt"
  if [[ -f "$feedback_path" && "$prompt" == *"Verifier feedback from the previous attempt:"* && "$prompt" == *"force-close-category"* ]]; then
    content="fixed-after-feedback"
  fi
  mkdir -p "$workspace_root/notes" "$workspace_root/.clasp-test-tmp" "$workspace_root/benchmarks/workspaces/generated"
  printf '%s\n' "$content" >"$workspace_path"
  printf '%s\n' "$content" >"$artifact_path"
  printf '%s\n' 'transient-noise' >"$workspace_root/.clasp-test-tmp/noise.txt"
  printf '%s\n' 'generated-benchmark-noise' >"$workspace_root/benchmarks/workspaces/generated/noise.txt"
  emit_report_payload <<JSON
{"summary":"builder wrote $content","files_touched":["workspace.txt","notes/child-artifact.txt"],"tests_run":[],"residual_risks":[],"feedback":{"summary":"use verifier feedback","ergonomics":["ordinary loop works"],"follow_ups":["keep direct codex invocation"],"warnings":[]}}
JSON
elif [[ "$prompt" == *"verifier subagent"* ]]; then
  printf '{"phase":"verifier-start"}\n'
  printf 'verifier-progress\n' >&2
  sleep "${CLASP_TEST_FAKE_CODEX_SLEEP_SECS:-0}"
  content=""
  if [[ -f "$workspace_path" ]]; then
    content="$(cat "$workspace_path")"
  fi
  if [[ "$content" == "fixed-after-feedback" ]]; then
    emit_report_payload <<'JSON'
{"verdict":"pass","summary":"feedback loop converged","findings":[],"tests_run":["workspace converged"],"follow_up":[],"capability_statuses":[{"name":"ordinary_program_execution","status":"pass","evidence":["workspace converged after verifier feedback"],"blocking_gaps":[],"required_closure":[]},{"name":"durable_native_substrate","status":"pass","evidence":["native substrate persisted state, events, runs, artifacts, approvals, and merge policy"],"blocking_gaps":[],"required_closure":[]},{"name":"clasp_native_control_api","status":"pass","evidence":["ordinary FeedbackLoop.clasp code drove the native swarm API directly"],"blocking_gaps":[],"required_closure":[]},{"name":"orchestration_viability","status":"pass","evidence":["builder/verifier retry loop completed end to end"],"blocking_gaps":[],"required_closure":[]},{"name":"ergonomics","status":"pass","evidence":["fixture exercises state-heavy records, empty lists, and JSON persistence"],"blocking_gaps":[],"required_closure":[]},{"name":"verification_gate","status":"pass","evidence":["workspace converged"],"blocking_gaps":[],"required_closure":[]}]}
JSON
  else
    printf '%s\n' 'force-close-category' >"$builder_policy_path"
    emit_report_payload <<'JSON'
{"verdict":"fail","summary":"workspace still needs feedback","findings":["workspace.txt still has the first-attempt content"],"tests_run":["workspace converged"],"follow_up":["Close the ordinary_program_execution category by using the verifier feedback to update workspace.txt."],"capability_statuses":[{"name":"ordinary_program_execution","status":"fail","evidence":["workspace.txt still has the first-attempt content"],"blocking_gaps":["builder did not consume the previous verifier feedback"],"required_closure":["Use the verifier feedback to update workspace.txt."]},{"name":"durable_native_substrate","status":"pass","evidence":["first failed verifier report was persisted for the retry"],"blocking_gaps":[],"required_closure":[]},{"name":"clasp_native_control_api","status":"pass","evidence":["direct Codex invocation path is present in the fixture"],"blocking_gaps":[],"required_closure":[]},{"name":"orchestration_viability","status":"fail","evidence":["loop has not converged yet"],"blocking_gaps":["builder/verifier cycle has not closed the blocking category"],"required_closure":["Make the next builder attempt consume the previous verifier feedback and converge."]},{"name":"ergonomics","status":"pass","evidence":["test fixture does not expose ergonomic blockers"],"blocking_gaps":[],"required_closure":[]},{"name":"verification_gate","status":"fail","evidence":["final convergence has not happened yet"],"blocking_gaps":["workspace still fails the acceptance check"],"required_closure":["Converge the workspace on the next attempt."]}]}
JSON
  fi
else
  printf 'unknown prompt\n' >&2
  exit 1
fi
EOF
chmod +x "$fake_codex"

if [[ -n "${CLASP_CLASPC:-}" ]]; then
  claspc_bin="$CLASP_CLASPC"
elif [[ -n "${CLASPC_BIN:-}" ]]; then
  claspc_bin="$CLASPC_BIN"
else
  claspc_bin="$(env -u CLASP_CLASPC -u CLASPC_BIN CLASP_PROJECT_ROOT="$project_root" "$project_root/scripts/resolve-claspc.sh")"
fi

grep -F 'codexCommand' "$demo_path" >/dev/null
grep -F '"exec"' "$demo_path" >/dev/null
grep -F 'toolRun (builderHandle attempt) (builderCommand attempt)' "$demo_path" >/dev/null
grep -F 'verifierRun (verifierHandle attempt) "autonomous-confidence" (verifierCommand attempt)' "$demo_path" >/dev/null

CLASP_LOOP_CODEX_BIN_JSON="\"$fake_codex\"" \
  timeout "$timeout_secs" "$claspc_bin" --json check "$demo_path" |
  grep -F '"status":"ok"' >/dev/null

mkdir -p "$workspace_root"
CLASP_LOOP_CODEX_BIN_JSON="\"$fake_codex\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$workspace_root\"" \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='2' \
  timeout "$timeout_secs" "$claspc_bin" run "$demo_path" -- "$state_root" >"$run_output"

CLASP_LOOP_COMMAND=status \
  timeout "$timeout_secs" "$claspc_bin" run "$demo_path" -- "$state_root" >"$status_output"
timeout "$timeout_secs" "$claspc_bin" --json swarm objective status "$state_root" autonomous-confidence >"$objective_output"
timeout "$timeout_secs" "$claspc_bin" swarm status "$state_root" verifier-2 >"$verifier_status_output"
timeout "$timeout_secs" "$claspc_bin" --json swarm approvals "$state_root" verifier-2 >"$approvals_output"
timeout "$timeout_secs" "$claspc_bin" --json swarm tail "$state_root" verifier-2 --limit 6 >"$tail_output"
timeout "$timeout_secs" "$claspc_bin" --json swarm runs "$state_root" builder-2 >"$builder_runs_output"
timeout "$timeout_secs" "$claspc_bin" --json swarm runs "$state_root" verifier-2 >"$verifier_runs_output"
timeout "$timeout_secs" "$claspc_bin" --json swarm artifacts "$state_root" builder-2 >"$builder_artifacts_output"

node - \
  "$run_output" \
  "$status_output" \
  "$objective_output" \
  "$verifier_status_output" \
  "$approvals_output" \
  "$tail_output" \
  "$builder_runs_output" \
  "$verifier_runs_output" \
  "$builder_artifacts_output" \
  "$workspace_root/workspace.txt" \
  "$state_root/feedback.json" \
  "$state_root/verifier-1.json" <<'NODE'
const fs = require("node:fs");

const [
  runPath,
  statusPath,
  objectivePath,
  verifierStatusPath,
  approvalsPath,
  tailPath,
  builderRunsPath,
  verifierRunsPath,
  builderArtifactsPath,
  workspacePath,
  feedbackPath,
  firstVerifierPath,
] = process.argv.slice(2);

function readText(path) {
  return fs.readFileSync(path, "utf8");
}

function readJson(path) {
  return JSON.parse(readText(path));
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function assertIncludes(path, fragment, label) {
  const text = readText(path);
  assert(text.includes(fragment), `${label} missing ${fragment}`);
}

function statusState(view) {
  return view.state || {};
}

const run = readJson(runPath);
const status = readJson(statusPath);
const objectiveText = readText(objectivePath);
const verifierStatus = readText(verifierStatusPath);
const approvalsText = readText(approvalsPath);
const tailText = readText(tailPath);
const builderRunsText = readText(builderRunsPath);
const verifierRunsText = readText(verifierRunsPath);
const builderArtifactsText = readText(builderArtifactsPath);
const feedback = readJson(feedbackPath);
const firstVerifier = readJson(firstVerifierPath);

assert(statusState(run).objectiveId === "autonomous-confidence", "run should report objective id");
assert(statusState(run).attempt === 2, `run attempt ${statusState(run).attempt}`);
assert(statusState(run).phase === "completed", `run phase ${statusState(run).phase}`);
assert(statusState(run).verdict === "pass", `run verdict ${statusState(run).verdict}`);
assert(run.objectiveProjectedStatus === "completed", `run projected ${run.objectiveProjectedStatus}`);
assert(run.taskCount === 4, `run taskCount ${run.taskCount}`);
assert(run.approvalCount === 1, `run approvalCount ${run.approvalCount}`);
assert(run.mergeDecisionDetail === "Mergegate `autonomous-confidence` decided pass.", "run merge detail");
assert(run.mergeGateSatisfied === true, "run merge gate should be satisfied");
assert(run.previousVerifierFeedback?.present === true, "run should include previous feedback");
assert(run.retryDecision?.attempt === 2 && run.retryDecision?.terminal === true, "run retry decision should be terminal");
assert(run.terminalOutcome?.builderTaskId === "builder-2", "run terminal builder task");
assert(run.terminalOutcome?.verifierTaskId === "verifier-2", "run terminal verifier task");
assert(run.allTaskIds.includes("builder-1") && run.allTaskIds.includes("verifier-2"), "run should include attempt task ids");

assert(statusState(status).attempt === 2, `status attempt ${statusState(status).attempt}`);
assert(statusState(status).phase === "completed", `status phase ${statusState(status).phase}`);
assert(statusState(status).verdict === "pass", `status verdict ${statusState(status).verdict}`);
assert(Array.isArray(status.readyTaskIds) && status.readyTaskIds.length === 0, "status ready tasks should be empty");
assert(status.approvalCount === 1, `status approvalCount ${status.approvalCount}`);
assert(status.mergeGateSatisfied === true, "status merge gate should be satisfied");
assert(status.previousVerifierFeedback?.present === true, "status should include previous feedback");
assert(status.terminalOutcome?.final === true, "status terminal outcome should be final");

assert(objectiveText.includes('"objectiveId":"autonomous-confidence"'), "objective status id");
assert(objectiveText.includes('"projectedStatus":"completed"'), "objective projected status");
assert(objectiveText.includes('"taskCount":4'), "objective task count");
assert(objectiveText.includes('"taskId":"builder-2"'), "objective should include builder-2");
assert(objectiveText.includes('"taskId":"verifier-2"'), "objective should include verifier-2");
assert(objectiveText.includes('"mergegateName":"autonomous-confidence"'), "objective should include mergegate");
assert(objectiveText.includes('"satisfied":true'), "objective mergegate should be satisfied");

assert(verifierStatus.includes("merge policy: autonomous-confidence satisfied=true"), "human status should show satisfied merge policy");
assert(approvalsText.includes('"name":"merge-ready"'), "approvals should include merge-ready");
assert(tailText.includes('"kind":"approval_granted"'), "tail should include approval event");
assert(tailText.includes('"kind":"mergegate_decision"'), "tail should include mergegate event");
assert(tailText.includes('"verdict":"pass"'), "tail should include pass verdict");
assert(builderRunsText.includes('"role":"tool"'), "builder runs should include tool role");
assert(builderRunsText.includes('"status":"passed"'), "builder runs should pass");
assert(verifierRunsText.includes('"role":"verifier"'), "verifier runs should include verifier role");
assert(verifierRunsText.includes('"status":"passed"'), "verifier runs should pass");
assert(builderArtifactsText.includes('"kind":"stdout"'), "builder artifacts should include stdout");
assert(builderArtifactsText.includes('"kind":"stderr"'), "builder artifacts should include stderr");

assert(readText(workspacePath) === "fixed-after-feedback\n", "workspace should converge after feedback");
assert(feedback.verdict === "pass", `feedback verdict ${feedback.verdict}`);
assert(firstVerifier.verdict === "fail", `first verifier verdict ${firstVerifier.verdict}`);
assert(firstVerifier.summary === "workspace still needs feedback", "first verifier summary");
assert(
  JSON.stringify(firstVerifier).includes("Close the ordinary_program_execution category by using the verifier feedback"),
  "first verifier should include actionable feedback",
);

assertIncludes(builderRunsPath, "builder-2", "builder runs");
NODE

printf 'swarm-native-feedback-loop: ok\n'
