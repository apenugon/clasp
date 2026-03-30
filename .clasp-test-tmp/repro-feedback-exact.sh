#!/usr/bin/env bash
set -euo pipefail
project_root="$(pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-.clasp-test-tmp}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"
test_root="$(mktemp -d "$TMPDIR/repro-feedback-exact.XXXXXX")"
test_root_abs="$(cd "$test_root" && pwd -P)"
export XDG_CACHE_HOME="$test_root/xdg-cache"
mkdir -p "$XDG_CACHE_HOME"
claspc_bin="$($project_root/scripts/resolve-claspc.sh)"
feedback_loop_binary="$test_root/feedback-loop-app"
feedback_loop_codex_bin="$test_root/codex"
feedback_loop_task_file="$test_root/feedback-loop-task.md"
feedback_loop_state_root="$test_root/feedback-loop-state"
feedback_loop_workspace_root="$test_root/feedback-loop-workspace"
feedback_loop_workspace="$feedback_loop_workspace_root/workspace.txt"
feedback_loop_noise_root="$feedback_loop_workspace_root/.clasp-test-tmp"
feedback_loop_noise_path="$feedback_loop_noise_root/noise.txt"
feedback_loop_first_verifier_path="$feedback_loop_state_root/verifier-1.json"
feedback_loop_feedback_path="$feedback_loop_state_root/feedback.json"
feedback_loop_first_diff_path="$feedback_loop_state_root/changes-1.diff"
feedback_loop_second_diff_path="$feedback_loop_state_root/changes-2.diff"
mkdir -p "$feedback_loop_workspace_root"
mkdir -p "$feedback_loop_noise_root"
cat >"$feedback_loop_task_file" <<'TASK'
Make the feedback loop converge after verifier feedback.
TASK
printf '%s\n' 'transient-noise' >"$feedback_loop_noise_path"
cat >"$feedback_loop_codex_bin" <<'CODEX'
#!/usr/bin/env bash
set -euo pipefail
workspace_root="."
report_path=""
prompt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cd)
      workspace_root="$2"
      shift 2
      ;;
    -o|--output-last-message)
      report_path="$2"
      shift 2
      ;;
    *)
      prompt="$1"
      shift
      ;;
  esac
done
if [[ -z "$report_path" ]]; then
  printf 'missing report path\n' >&2
  exit 1
fi
workspace_path="$workspace_root/workspace.txt"
feedback_path="$(dirname "$report_path")/feedback.json"
builder_policy_path="$(dirname "$report_path")/builder-policy.md"
if [[ "$prompt" == *"builder subagent"* ]]; then
  printf '{"phase":"builder-start"}\n'
  printf 'builder-progress\n' >&2
  sleep 0.3
  content="first-attempt"
  if [[ -f "$feedback_path" && "$prompt" == *"Verifier feedback from the previous attempt:"* && "$prompt" == *"force-close-category"* ]]; then
    content="fixed-after-feedback"
  fi
  printf '%s\n' "$content" >"$workspace_path"
  cat >"$report_path" <<JSON
{"summary":"builder wrote $content","files_touched":["workspace.txt"],"tests_run":[],"residual_risks":[],"feedback":{"summary":"use verifier feedback","ergonomics":["ordinary loop works"],"follow_ups":["keep direct codex invocation"],"warnings":[]}}
JSON
elif [[ "$prompt" == *"verifier subagent"* ]]; then
  printf '{"phase":"verifier-start"}\n'
  printf 'verifier-progress\n' >&2
  sleep 0.3
  content=""
  if [[ -f "$workspace_path" ]]; then
    content="$(cat "$workspace_path")"
  fi
  if [[ "$content" == "fixed-after-feedback" ]]; then
    cat >"$report_path" <<'JSON'
{"verdict":"pass","summary":"feedback loop converged","findings":[],"tests_run":["workspace converged"],"follow_up":[],"capability_statuses":[{"name":"ordinary_program_execution","status":"pass","evidence":["workspace converged after verifier feedback"],"blocking_gaps":[],"required_closure":[]},{"name":"durable_native_substrate","status":"pass","evidence":["test fixture does not model substrate gaps"],"blocking_gaps":[],"required_closure":[]},{"name":"clasp_native_control_api","status":"pass","evidence":["feedback loop prompt included previous verifier feedback directly"],"blocking_gaps":[],"required_closure":[]},{"name":"orchestration_viability","status":"pass","evidence":["ordinary loop completed end to end"],"blocking_gaps":[],"required_closure":[]},{"name":"ergonomics","status":"pass","evidence":["test fixture did not expose ergonomic blockers"],"blocking_gaps":[],"required_closure":[]},{"name":"verification_gate","status":"pass","evidence":["workspace converged"],"blocking_gaps":[],"required_closure":[]}]}
JSON
  else
    printf '%s\n' 'force-close-category' >"$builder_policy_path"
    cat >"$report_path" <<'JSON'
{"verdict":"fail","summary":"workspace still needs feedback","findings":["workspace.txt still has the first-attempt content"],"tests_run":["workspace converged"],"follow_up":["Close the ordinary_program_execution category by using the verifier feedback to update workspace.txt."],"capability_statuses":[{"name":"ordinary_program_execution","status":"fail","evidence":["workspace.txt still has the first-attempt content"],"blocking_gaps":["builder did not consume the previous verifier feedback"],"required_closure":["Use the verifier feedback to update workspace.txt."]},{"name":"durable_native_substrate","status":"pass","evidence":["test fixture does not model substrate gaps"],"blocking_gaps":[],"required_closure":[]},{"name":"clasp_native_control_api","status":"pass","evidence":["direct Codex invocation path is present in the fixture"],"blocking_gaps":[],"required_closure":[]},{"name":"orchestration_viability","status":"fail","evidence":["loop has not converged yet"],"blocking_gaps":["builder/verifier cycle has not closed the blocking category"],"required_closure":["Make the next builder attempt consume the previous verifier feedback and converge."]},{"name":"ergonomics","status":"pass","evidence":["test fixture does not expose ergonomic blockers"],"blocking_gaps":[],"required_closure":[]},{"name":"verification_gate","status":"fail","evidence":["final convergence has not happened yet"],"blocking_gaps":["workspace still fails the acceptance check"],"required_closure":["Converge the workspace on the next attempt."]}]}
JSON
  fi
else
  printf 'unknown prompt\n' >&2
  exit 1
fi
CODEX
chmod +x "$feedback_loop_codex_bin"
"$claspc_bin" --json check "$project_root/examples/feedback-loop/Main.clasp" | grep -F '"status":"ok"' >/dev/null
set +e
feedback_loop_output="$({
  CLASP_LOOP_CODEX_BIN_JSON="\"$feedback_loop_codex_bin\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$feedback_loop_task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$feedback_loop_workspace_root\"" \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='2' \
  CLASP_LOOP_TRACE_JSON='1' \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$feedback_loop_state_root"
} 2>"$test_root/run.stderr")"
status=$?
set -e
printf 'ROOT=%s\nSTATUS=%s\nOUT=%s\n' "$test_root" "$status" "$feedback_loop_output"
for file in \
  "$feedback_loop_state_root/trace.log" \
  "$feedback_loop_state_root/state.json" \
  "$feedback_loop_state_root/builder-1.json" \
  "$feedback_loop_state_root/verifier-1.json" \
  "$feedback_loop_state_root/builder-2.json" \
  "$feedback_loop_state_root/verifier-2.json" \
  "$feedback_loop_feedback_path" \
  "$feedback_loop_first_diff_path" \
  "$feedback_loop_second_diff_path" \
  "$feedback_loop_workspace" \
  "$test_root/run.stderr"; do
  if [[ -f "$file" ]]; then
    printf '--- %s ---\n' "$file"
    cat "$file"
    printf '\n'
  fi
done
