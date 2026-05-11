#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"

test_root="$(mktemp -d "$TMPDIR/test-goal-manager-fast.XXXXXX")"
test_root_abs="$(cd "$test_root" && pwd -P)"
export XDG_CACHE_HOME="$test_root/xdg-cache"
goal_manager_shared_cache_root="${CLASP_GOAL_MANAGER_SHARED_CACHE_PROJECT_ROOT:-${CLASP_MANAGER_PROJECT_ROOT_JSON:-$project_root}}"
goal_manager_build_cache_dir="${CLASP_GOAL_MANAGER_CACHE_DIR:-$goal_manager_shared_cache_root/.clasp-loops/.cache/goal-manager-fast/binaries}"
goal_manager_build_xdg_cache_home="${CLASP_GOAL_MANAGER_BUILD_XDG_CACHE_HOME:-$goal_manager_shared_cache_root/.clasp-loops/.cache/goal-manager-fast/xdg-cache}"
export CLASP_GOAL_MANAGER_COMPILE_TIMEOUT_SECS="${CLASP_GOAL_MANAGER_COMPILE_TIMEOUT_SECS:-60}"
export CLASP_GOAL_MANAGER_COMPILE_ATTEMPTS="${CLASP_GOAL_MANAGER_COMPILE_ATTEMPTS:-1}"
export CLASP_GOAL_MANAGER_ALLOW_STALE_ON_COMPILE_FAILURE="${CLASP_GOAL_MANAGER_ALLOW_STALE_ON_COMPILE_FAILURE:-1}"

goal_manager_live_pid=""
goal_manager_monolithic_source="$project_root/examples/swarm-native/GoalManager.clasp"
goal_manager_wrapper_source="$project_root/examples/swarm-native/GoalManager.wrapper.clasp"
goal_manager_source="${CLASP_GOAL_MANAGER_SOURCE:-$goal_manager_monolithic_source}"
goal_manager_live_binary="$project_root/.clasp-loops/.cache/goal-manager-live/swarm-goal-manager"
goal_manager_actual_binary="$project_root/.clasp-loops/.cache/goal-manager-planner-memory/swarm-goal-manager"

cleanup() {
  set +e
  if [[ -n "$goal_manager_live_pid" ]]; then
    kill "$goal_manager_live_pid" >/dev/null 2>&1 || true
    wait "$goal_manager_live_pid" >/dev/null 2>&1 || true
  fi
  mapfile -t cleanup_descendant_pids < <(pgrep -f "$test_root" 2>/dev/null || true)
  if [[ ${#cleanup_descendant_pids[@]} -gt 0 ]]; then
    kill "${cleanup_descendant_pids[@]}" >/dev/null 2>&1 || true
    sleep 0.1
    kill -9 "${cleanup_descendant_pids[@]}" >/dev/null 2>&1 || true
  fi
  if [[ "${CLASP_KEEP_TEST_TMP:-}" != "1" ]]; then
    rm -rf "$test_root" >/dev/null 2>&1 || true
  else
    printf 'kept test root: %s\n' "$test_root_abs" >&2
  fi
}

trap cleanup EXIT

trace_case() {
  if [[ "${CLASP_TRACE_GOAL_MANAGER_FAST:-}" == "1" ]]; then
    printf '[test-goal-manager-fast] %s\n' "$1" >&2
  fi
}

wait_for_path_contains() {
  local path="$1"
  local pattern="$2"
  local live_pid="${3:-}"
  local attempts="${4:-300}"
  local sleep_seconds="${5:-0.05}"
  local attempt

  for attempt in $(seq 1 "$attempts"); do
    if [[ -f "$path" ]] && grep -F "$pattern" "$path" >/dev/null 2>&1; then
      return 0
    fi
    if [[ -n "$live_pid" ]] && ! kill -0 "$live_pid" >/dev/null 2>&1; then
      break
    fi
    sleep "$sleep_seconds"
  done

  echo "timed out waiting for '$pattern' in $path" >&2
  if [[ -f "$path" ]]; then
    sed -n '1,80p' "$path" >&2 || true
  fi
  return 1
}

json_number_field() {
  local path="$1"
  local field="$2"

  if [[ ! -f "$path" ]]; then
    return 0
  fi

  grep -o "\"$field\":[0-9]*" "$path" 2>/dev/null | head -1 | cut -d: -f2
}

file_hash_or_missing() {
  local path="$1"

  if [[ -e "$path" ]]; then
    sha256sum "$path" | awk '{print "file:" $1}'
  else
    printf 'missing\n'
  fi
}

service_supervisor_pid_for() {
  local state_root="$1"
  local supervisor_config="$state_root/service/supervisor.config.json"

  ps -eo pid=,args= | while read -r pid args; do
    case "$args" in
      *"$supervisor_config"*)
        if [[ "$pid" != "$$" ]]; then
          printf '%s\n' "$pid"
          break
        fi
        ;;
    esac
  done
}

kill_pid_if_live() {
  local pid="$1"

  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
  fi
}

wait_or_kill_pid() {
  local pid="$1"
  local attempts="${2:-200}"
  local attempt

  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    return 0
  fi

  for attempt in $(seq 1 "$attempts"); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
  done

  kill "$pid" >/dev/null 2>&1 || true
  sleep 0.1
  kill -9 "$pid" >/dev/null 2>&1 || true
}

stop_goal_manager_service() {
  local state_root="$1"
  local service_json="$state_root/service/service.json"
  local owner_pid
  local supervisor_pid

  owner_pid="$(json_number_field "$service_json" "ownerPid")"
  supervisor_pid="$(service_supervisor_pid_for "$state_root" | head -1)"
  kill_pid_if_live "$supervisor_pid"
  kill_pid_if_live "$owner_pid"
  wait_or_kill_pid "$supervisor_pid" 100
  wait_or_kill_pid "$owner_pid" 100
  rm -f "$state_root/service/supervisor.lock"
}

claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
fake_codex_bin="$test_root_abs/codex"
fake_child_claspc_bin="$test_root_abs/fake-claspc"
fake_passing_benchmark_bin="$test_root_abs/fake-benchmark-passing"
fake_slow_benchmark_bin="$test_root_abs/fake-benchmark-slow"
fake_replan_benchmark_bin="$test_root_abs/fake-benchmark-replan"
goal_manager_binary="${CLASP_GOAL_MANAGER_BINARY:-}"
split_goal_manager_binary="$test_root_abs/split-goal-manager"
goal_manager_binary_fresh=1
grep -F 'plannerPromptFor wave benchmarkSummary' "$project_root/examples/swarm-native/GoalManagerBootstrapPlanner.clasp" >/dev/null
grep -F 'import GoalManagerServiceMain' "$goal_manager_wrapper_source" >/dev/null
grep -F 'runManagedServiceBootstrap' "$goal_manager_monolithic_source" >/dev/null
mkdir -p "$test_root_abs/bin"

fake_ensure_claspc_bin="$test_root_abs/fake-ensure-claspc"
fake_ensure_log="$test_root_abs/fake-ensure-claspc.log"
cat >"$fake_ensure_claspc_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
source_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    *.clasp)
      source_path="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$output" ]]; then
  printf 'missing -o\n' >&2
  exit 1
fi

if [[ -n "${CLASP_TEST_FAKE_ENSURE_CLASPC_LOG:-}" ]]; then
  printf 'compile-source=%s\n' "$source_path" >>"$CLASP_TEST_FAKE_ENSURE_CLASPC_LOG"
  printf 'compile-output=%s\n' "$output" >>"$CLASP_TEST_FAKE_ENSURE_CLASPC_LOG"
fi

cat >"$output" <<SCRIPT
#!/usr/bin/env bash
printf 'compiled-source=%s\n' '$source_path'
printf 'compiled-output=%s\n' '$output'
printf 'compiled-threshold=%s\n' '$CLASP_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD'
exit 0
SCRIPT
EOF
chmod +x "$fake_ensure_claspc_bin"

ensure_probe_cache="$test_root_abs/ensure-goal-manager-cache"
ensure_probe_alias="$test_root_abs/ensure-goal-manager-alias/swarm-goal-manager"
mkdir -p "$(dirname "$ensure_probe_alias")"
printf '#!/usr/bin/env bash\nexit 42\n' >"$ensure_probe_alias"
chmod +x "$ensure_probe_alias"
ensure_probe_binary_one="$(
  CLASP_TEST_FAKE_ENSURE_CLASPC_LOG="$fake_ensure_log" \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$fake_ensure_claspc_bin" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$ensure_probe_cache" \
    "$project_root/scripts/ensure-goal-manager-binary.sh" \
    --alias "$ensure_probe_alias"
)"
ensure_probe_binary_two="$(
  CLASP_TEST_FAKE_ENSURE_CLASPC_LOG="$fake_ensure_log" \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$fake_ensure_claspc_bin" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$ensure_probe_cache" \
    "$project_root/scripts/ensure-goal-manager-binary.sh"
)"
[[ "$ensure_probe_binary_one" == "$ensure_probe_binary_two" ]]
[[ "$(grep -c '^compile-source=' "$fake_ensure_log")" == "1" ]]
grep -F "compile-source=$goal_manager_source" "$fake_ensure_log" >/dev/null
cmp -s "$ensure_probe_binary_one" "$ensure_probe_alias"
"$ensure_probe_alias" | grep -F "compiled-source=$goal_manager_source" >/dev/null

ensure_probe_binary_build_mode="$(
  CLASP_TEST_FAKE_ENSURE_CLASPC_LOG="$fake_ensure_log" \
    CLASP_NATIVE_IMAGE_MONOLITHIC_DECL_THRESHOLD=1 \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$fake_ensure_claspc_bin" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$ensure_probe_cache" \
    "$project_root/scripts/ensure-goal-manager-binary.sh" \
    --alias "$ensure_probe_alias"
)"
[[ "$ensure_probe_binary_build_mode" != "$ensure_probe_binary_one" ]]
[[ "$(grep -c '^compile-source=' "$fake_ensure_log")" == "2" ]]
cmp -s "$ensure_probe_binary_build_mode" "$ensure_probe_alias"
"$ensure_probe_alias" | grep -F 'compiled-threshold=1' >/dev/null

ensure_probe_monolithic_binary="$(
  CLASP_TEST_FAKE_ENSURE_CLASPC_LOG="$fake_ensure_log" \
    CLASP_GOAL_MANAGER_SOURCE="$goal_manager_monolithic_source" \
    CLASP_GOAL_MANAGER_CLASPC_BIN="$fake_ensure_claspc_bin" \
    CLASP_GOAL_MANAGER_CACHE_DIR="$ensure_probe_cache" \
    "$project_root/scripts/ensure-goal-manager-binary.sh"
)"
if [[ "$goal_manager_source" == "$goal_manager_monolithic_source" ]]; then
  [[ "$ensure_probe_monolithic_binary" == "$ensure_probe_binary_one" ]]
  [[ "$(grep -c '^compile-source=' "$fake_ensure_log")" == "2" ]]
else
  [[ "$ensure_probe_monolithic_binary" != "$ensure_probe_binary_one" ]]
  grep -F "compile-source=$goal_manager_monolithic_source" "$fake_ensure_log" >/dev/null
  [[ "$(grep -c '^compile-source=' "$fake_ensure_log")" == "3" ]]
fi

if [[ "${CLASP_GOAL_MANAGER_FAST_CACHE_PROBE_ONLY:-0}" == "1" ]]; then
  printf 'goal-manager-fast-cache-probe-ok\n'
  exit 0
fi

cat >"$fake_codex_bin" <<'EOF'
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
      workspace_root="$2"
      shift 2
      ;;
    -m|-c|--sandbox|--output-schema)
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

if [[ "$prompt" == "-" ]]; then
  prompt="$(cat)"
fi

if [[ -z "$report_path" ]]; then
  printf 'missing report path\n' >&2
  exit 1
fi

feedback_path="$(dirname "$report_path")/feedback.json"
builder_policy_path="$(dirname "$report_path")/builder-policy.md"
planner_mode="${CLASP_TEST_FAKE_PLANNER_MODE:-benchmark-replan}"
task_loop="$(basename "$(dirname "$report_path")")"
task_id="${task_loop#loop-}"
report_basename="$(basename "$report_path")"
workspace_file="workspace.txt"
artifact_file="child-artifact.txt"
if [[ "$planner_mode" == "parallel-ready" && "${CLASP_TEST_FAKE_PROMOTION_CONFLICT:-0}" != "1" ]]; then
  workspace_file="$task_id.txt"
  artifact_file="$task_id.txt"
fi
workspace_path="$workspace_root/$workspace_file"
artifact_path="$workspace_root/notes/$artifact_file"
planner_transient_fails="${CLASP_TEST_FAKE_PLANNER_TRANSIENT_FAILS:-0}"
planner_transient_marker="$(dirname "$report_path")/.fake-planner-transient-$(basename "$report_path")"
planner_overbudget_fails="${CLASP_TEST_FAKE_PLANNER_OVERBUDGET_FAILS:-0}"
planner_overbudget_marker="$(dirname "$report_path")/.fake-planner-overbudget-$(basename "$report_path")"
planner_timeout_fails="${CLASP_TEST_FAKE_PLANNER_TIMEOUT_FAILS:-0}"
planner_timeout_marker="$(dirname "$report_path")/.fake-planner-timeout-$(basename "$report_path")"
planner_usage_limit_fails="${CLASP_TEST_FAKE_PLANNER_USAGE_LIMIT_FAILS:-0}"
planner_usage_limit_marker="$(dirname "$report_path")/.fake-planner-usage-limit-$(basename "$report_path")"
planner_sleep_secs="${CLASP_TEST_FAKE_PLANNER_SLEEP_SECS:-${CLASP_TEST_FAKE_CODEX_SLEEP_SECS:-0.05}}"
planner_timeout_sleep_secs="${CLASP_TEST_FAKE_PLANNER_TIMEOUT_SLEEP_SECS:-2}"
planner_wave2_sleep_secs="${CLASP_TEST_FAKE_PLANNER_WAVE2_SLEEP_SECS:-}"

if [[ "$prompt" == *"planner subagent"* || "$report_basename" == planner-*.json ]]; then
  if [[ "${CLASP_TEST_FAIL_IF_PLANNER_RUN:-0}" == "1" ]]; then
    printf 'planner should not run for this preflight failure case\n' >&2
    exit 53
  fi
  if [[ "${CLASP_TEST_EXPECT_PLANNER_HEALTH:-0}" == "1" && "$prompt" != *"Current manager health/resource context:"* ]]; then
    printf 'planner prompt missing manager health context
' >&2
    exit 45
  fi
  if [[ "${CLASP_TEST_EXPECT_PLANNER_NO_BROAD_VERIFY:-0}" == "1" && "$prompt" != *"Do not run repo-wide verification, benchmarks, builds, package installs, or other long commands from the planner."* ]]; then
    printf 'planner prompt missing no-broad-verification contract
' >&2
    exit 54
  fi
  if [[ -n "${CLASP_TEST_EXPECT_PLANNER_TASK_LIMIT:-}" ]]; then
    expected_limit_line="Plan 1-${CLASP_TEST_EXPECT_PLANNER_TASK_LIMIT} bounded tasks with explicit dependencies and task prompts."
    if [[ "$prompt" != *"$expected_limit_line"* ]]; then
      printf 'planner prompt missing task limit contract
' >&2
      exit 49
    fi
  fi
  if [[ "$planner_transient_fails" =~ ^[0-9]+$ ]] && (( planner_transient_fails > 0 )); then
    planner_fail_count="0"
    if [[ -f "$planner_transient_marker" ]]; then
      planner_fail_count="$(cat "$planner_transient_marker")"
    fi
    if (( planner_fail_count < planner_transient_fails )); then
      printf '%s
' "$((planner_fail_count + 1))" >"$planner_transient_marker"
      printf '%s
' "We're currently experiencing high demand, which may cause temporary errors."
      printf '%s
' 'stream disconnected before completion: websocket closed by server before response.completed'
      printf '%s
' 'turn.failed'
      printf '%s
' 'Reading additional input from stdin...' >&2
      exit 48
    fi
  fi
  if [[ "$planner_usage_limit_fails" =~ ^[0-9]+$ ]] && (( planner_usage_limit_fails > 0 )); then
    planner_usage_limit_count="0"
    if [[ -f "$planner_usage_limit_marker" ]]; then
      planner_usage_limit_count="$(cat "$planner_usage_limit_marker")"
    fi
    if (( planner_usage_limit_count < planner_usage_limit_fails )); then
      printf '%s
' "$((planner_usage_limit_count + 1))" >"$planner_usage_limit_marker"
      cat <<'JSONL'
{"type":"thread.started","thread_id":"fake-planner-usage-limit"}
{"type":"turn.started"}
{"type":"error","message":"You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at May 11th, 2026 11:07 PM."}
{"type":"turn.failed","error":{"message":"You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at May 11th, 2026 11:07 PM."}}
JSONL
      exit 55
    fi
  fi
  if [[ "$planner_timeout_fails" =~ ^[0-9]+$ ]] && (( planner_timeout_fails > 0 )); then
    planner_timeout_count="0"
    if [[ -f "$planner_timeout_marker" ]]; then
      planner_timeout_count="$(cat "$planner_timeout_marker")"
    fi
    if (( planner_timeout_count < planner_timeout_fails )); then
      printf '%s
' "$((planner_timeout_count + 1))" >"$planner_timeout_marker"
      sleep "$planner_timeout_sleep_secs"
    fi
  fi
  if [[ -n "$planner_wave2_sleep_secs" && "$prompt" == *"Wave: 2"* ]]; then
    sleep "$planner_wave2_sleep_secs"
  fi
  if [[ "${CLASP_TEST_EXPECT_WAVE2_MAILBOX:-0}" == "1" && "$prompt" == *"Wave: 2"* ]]; then
    if [[ "$prompt" != *"fake child builder report for benchmark-gap"* ]]; then
      printf 'planner prompt missing builder mailbox summary from completed task\n' >&2
      exit 50
    fi
    if [[ "$prompt" != *"finding=carry-forward finding for benchmark-gap"* ]]; then
      printf 'planner prompt missing verifier findings from completed task\n' >&2
      exit 51
    fi
    if [[ "$prompt" != *"follow-up=reuse mailbox context for benchmark-gap"* ]]; then
      printf 'planner prompt missing verifier follow-up from completed task\n' >&2
      exit 52
    fi
  fi
  sleep "$planner_sleep_secs"
  if [[ "${CLASP_TEST_FAKE_PLANNER_MALFORMED_REPORT:-0}" == "1" ]]; then
    cat >"$report_path" <<'JSON'
{"tasks":[]}
JSON
    exit 0
  fi
  if [[ "$planner_overbudget_fails" =~ ^[0-9]+$ ]] && (( planner_overbudget_fails > 0 )); then
    planner_overbudget_count="0"
    if [[ -f "$planner_overbudget_marker" ]]; then
      planner_overbudget_count="$(cat "$planner_overbudget_marker")"
    fi
    if (( planner_overbudget_count < planner_overbudget_fails )); then
      printf '%s
' "$((planner_overbudget_count + 1))" >"$planner_overbudget_marker"
      cat >"$report_path" <<'JSON'
{"objectiveSummary":"Repair planner/manager budget alignment.","strategy":"First emit an oversized plan to force same-wave validation recovery, then let the normal bounded plan succeed.","tasks":[{"taskId":"budget-contract-a","role":"control-plane-hardener","detail":"Exercise planner budget validation recovery with an oversized plan.","dependencies":[],"taskPrompt":"Exercise the manager's ability to reject an oversized planner report and request a bounded retry.","coordinationFocus":["planner-budget","validation-retry"]},{"taskId":"budget-contract-b","role":"verification-closer","detail":"Keep an extra independent task in the oversized plan so the manager must enforce its task cap.","dependencies":[],"taskPrompt":"Provide a second independent task so the fake planner report exceeds the configured task limit.","coordinationFocus":["planner-budget","parallel-cap"]}],"testsRun":["planned-with-fake-codex","oversized-plan"],"residualRisks":[]}
JSON
      exit 0
    fi
  fi
  if [[ "$planner_mode" == "parallel-ready" ]]; then
    cat >"$report_path" <<'JSON'
{"objectiveSummary":"Improve Clasp with parallel bounded branches.","strategy":"Run two independent bounded branches so the service supervisor has live child work to restart around.","tasks":[{"taskId":"stabilize-loop","role":"control-plane-hardener","detail":"Stabilize the ordinary Clasp feedback loop manager path.","dependencies":[],"taskPrompt":"Strengthen the ordinary Clasp loop path so it remains durable and easy to inspect.","coordinationFocus":["service-continuity","loop-durability"]},{"taskId":"tighten-verify","role":"verification-closer","detail":"Tighten verification and substrate inspection in parallel.","dependencies":[],"taskPrompt":"Tighten verification coverage and substrate inspection as a parallel improvement branch.","coordinationFocus":["verification-gate","inspection-artifacts"]}],"testsRun":["planned-with-fake-codex","parallel-ready-plan"],"residualRisks":[]}
JSON
  else
    cat >"$report_path" <<'JSON'
{"objectiveSummary":"Reduce the AppBench gap with an initial wave.","strategy":"Start with one bounded implementation wave, then re-check the benchmark before deciding whether to continue.","tasks":[{"taskId":"benchmark-gap","role":"benchmark-operator","detail":"Close the first benchmark gap.","dependencies":[],"taskPrompt":"Make the first bounded improvement wave toward beating the benchmark target.","coordinationFocus":["baseline-gap","wave-planning"]}],"testsRun":["planned-with-fake-codex","benchmark-wave-1"],"residualRisks":[]}
JSON
  fi
elif [[ "$prompt" == *"builder subagent"* ]]; then
  sleep "${CLASP_TEST_FAKE_CODEX_SLEEP_SECS:-0.05}"
  content="first-attempt"
  if [[ -f "$feedback_path" && "$prompt" == *"Verifier feedback from the previous attempt:"* && "$prompt" == *"force-close-category"* ]]; then
    content="fixed-after-feedback"
  fi
  if [[ "${CLASP_TEST_FAKE_PROMOTION_CONFLICT:-0}" == "1" && "$content" == "fixed-after-feedback" ]]; then
    content="fixed-after-feedback-$task_id"
  fi
  printf '%s\n' "$content" >"$workspace_path"
  mkdir -p "$workspace_root/notes"
  printf '%s\n' "$content" >"$artifact_path"
  mkdir -p "$workspace_root/.clasp-test-tmp"
  printf '%s\n' 'transient-noise' >"$workspace_root/.clasp-test-tmp/noise.txt"
  if [[ "${CLASP_TEST_FAKE_CHILD_CORRUPT_WORKSPACE_MANIFEST:-0}" == "1" ]]; then
    printf '%s\n' '{"kind":"clasp-task-workspace","manifestVersion":1,"taskId":"wrong-task","snapshotPolicyId":"wrong-policy"}' >"$workspace_root/.clasp-task-workspace-manifest.json"
  fi
  cat >"$report_path" <<JSON
{"summary":"builder wrote $content","files_touched":["$workspace_file","notes/$artifact_file"],"tests_run":[],"residual_risks":[],"feedback":{"summary":"use verifier feedback","ergonomics":["ordinary loop works"],"follow_ups":["keep direct codex invocation"],"warnings":[]}}
JSON
elif [[ "$prompt" == *"verifier subagent"* ]]; then
  if [[ "${CLASP_TEST_EXPECT_FOCUSED_VERIFY_TIER:-0}" == "1" ]]; then
    if [[ "$prompt" != *"Verification tier: focused."* ]]; then
      printf 'verifier prompt missing focused verification tier\n' >&2
      exit 46
    fi
    if [[ "$prompt" == *"Run bash scripts/verify-all.sh before sign-off."* ]]; then
      printf 'verifier prompt still requires full verify-all for focused branch\n' >&2
      exit 47
    fi
  fi
  sleep "${CLASP_TEST_FAKE_CODEX_SLEEP_SECS:-0.05}"
  content=""
  if [[ -f "$workspace_path" ]]; then
    content="$(cat "$workspace_path")"
  fi
  if [[ "$content" == fixed-after-feedback* ]]; then
    cat >"$report_path" <<'JSON'
{"verdict":"pass","summary":"feedback loop converged","findings":[],"tests_run":["workspace converged"],"follow_up":[],"capability_statuses":[{"name":"ordinary_program_execution","status":"pass","evidence":["workspace converged after verifier feedback"],"blocking_gaps":[],"required_closure":[]},{"name":"durable_native_substrate","status":"pass","evidence":["test fixture does not model substrate gaps"],"blocking_gaps":[],"required_closure":[]},{"name":"clasp_native_control_api","status":"pass","evidence":["feedback loop prompt included previous verifier feedback directly"],"blocking_gaps":[],"required_closure":[]},{"name":"orchestration_viability","status":"pass","evidence":["ordinary loop completed end to end"],"blocking_gaps":[],"required_closure":[]},{"name":"ergonomics","status":"pass","evidence":["test fixture did not expose ergonomic blockers"],"blocking_gaps":[],"required_closure":[]},{"name":"verification_gate","status":"pass","evidence":["workspace converged"],"blocking_gaps":[],"required_closure":[]}]}
JSON
  else
    printf '%s\n' 'force-close-category' >"$builder_policy_path"
    cat >"$report_path" <<'JSON'
{"verdict":"fail","summary":"workspace still needs feedback","findings":["workspace.txt still has the first-attempt content"],"tests_run":["workspace converged"],"follow_up":["force-close-category"],"capability_statuses":[{"name":"ordinary_program_execution","status":"fail","evidence":["workspace.txt still has the first-attempt content"],"blocking_gaps":["builder did not consume verifier feedback"],"required_closure":["Use verifier feedback to update workspace.txt."]},{"name":"durable_native_substrate","status":"pass","evidence":["test fixture does not model substrate gaps"],"blocking_gaps":[],"required_closure":[]},{"name":"clasp_native_control_api","status":"pass","evidence":["direct Codex invocation path is present in the fixture"],"blocking_gaps":[],"required_closure":[]},{"name":"orchestration_viability","status":"fail","evidence":["loop has not converged yet"],"blocking_gaps":["builder/verifier cycle has not closed"],"required_closure":["Converge on the next attempt."]},{"name":"ergonomics","status":"pass","evidence":["test fixture does not expose ergonomic blockers"],"blocking_gaps":[],"required_closure":[]},{"name":"verification_gate","status":"fail","evidence":["final convergence has not happened yet"],"blocking_gaps":["workspace still fails acceptance"],"required_closure":["Converge the workspace on the next attempt."]}]}
JSON
  fi
else
  printf 'unknown prompt\n' >&2
  exit 1
fi
EOF
chmod +x "$fake_codex_bin"

cat >"$fake_child_claspc_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "run" ]]; then
  printf 'unsupported fake claspc command: %s\n' "$*" >&2
  exit 2
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
  printf 'missing fake child loop state root\n' >&2
  exit 2
fi

if [[ "${CLASP_TEST_EXPECT_CHILD_XDG_CACHE:-0}" == "1" && "${XDG_CACHE_HOME:-}" != "$state_root/xdg-cache" ]]; then
  printf 'child loop XDG_CACHE_HOME was not isolated: %s\n' "${XDG_CACHE_HOME:-}" >&2
  exit 44
fi

if [[ -n "${CLASP_MANAGER_BENCHMARK_COMMAND_JSON:-}" ]]; then
  printf 'child loop inherited manager benchmark command\n' >&2
  exit 42
fi

task_file="${CLASP_LOOP_TASK_FILE_JSON:-}"
task_file="${task_file%\"}"
task_file="${task_file#\"}"
if [[ -z "$task_file" ]]; then
  printf 'child loop missing task file env\n' >&2
  exit 45
fi
if [[ ! -f "$task_file" ]]; then
  printf 'child loop task file missing: %s\n' "$task_file" >&2
  exit 46
fi

workspace_root="${CLASP_LOOP_WORKSPACE_JSON:-}"
workspace_root="${workspace_root%\"}"
workspace_root="${workspace_root#\"}"
task_loop="$(basename "$state_root")"
task_id="${task_loop#loop-}"
if [[ "${CLASP_TEST_FAKE_CHILD_CRASH_NO_REPORT:-0}" == "1" && "$task_id" == "benchmark-gap" ]]; then
  mkdir -p "$state_root"
  printf 'fake child crashed before durable report for %s\n' "$task_id" >&2
  exit 43
fi

if [[ "${CLASP_TEST_FAKE_CHILD_CRASH_ONCE_NO_REPORT:-0}" == "1" && "$task_id" == "benchmark-gap" ]]; then
  marker="$(dirname "$state_root")/.fake-child-crashed-once-$task_id"
  if [[ ! -f "$marker" ]]; then
    mkdir -p "$state_root"
    printf 'crashed-once\n' >"$marker"
    printf 'fake child crashed once before durable report for %s\n' "$task_id" >&2
    exit 43
  fi
fi

if [[ "${CLASP_TEST_FAKE_CHILD_VERIFIER_EXPORT_CRASH_ONCE:-0}" == "1" && "$task_id" == "benchmark-gap" ]]; then
  marker="$(dirname "$state_root")/.fake-child-verifier-export-crashed-once-$task_id"
  if [[ ! -f "$marker" ]]; then
    mkdir -p "$state_root"
    if [[ "${CLASP_TEST_FAKE_CHILD_REQUIRE_PRESERVED_VERIFIER_STATE:-0}" == "1" ]]; then
      printf 'preserve-builder-progress\n' >"$workspace_root/preserve-builder-progress.txt"
    fi
    printf 'crashed-once\n' >"$marker"
    cat >"$state_root/state.json" <<'JSON'
{"attempt":1,"phase":"verifier-step-ready","verdict":"pending","completed":false,"builderRuns":1,"verifierRuns":1,"healthy":true,"needsAttention":false,"attentionReason":"","final":false}
JSON
    cat >"$state_root/builder-1.json" <<JSON
{"summary":"fake child builder report before verifier export crash for $task_id","files_touched":[],"tests_run":[],"residual_risks":[],"feedback":{"summary":"builder completed before verifier export crash","ergonomics":[],"follow_ups":[],"warnings":[]}}
JSON
    cat >"$state_root/changes-1.diff" <<DIFF
diff --git a/fake-$task_id.txt b/fake-$task_id.txt
--- a/fake-$task_id.txt
+++ b/fake-$task_id.txt
@@
+recoverable verifier export crash diff
DIFF
    printf "runtime failed to execute native compiler export 'main' from image fake-%s.native.image.json\n" "$task_id" >&2
    printf "fake verifier stdout before export crash for %s\n" "$task_id"
    exit 43
  fi
fi

if [[ "${CLASP_TEST_FAKE_CHILD_REQUIRE_PRESERVED_VERIFIER_STATE:-0}" == "1" && "$task_id" == "benchmark-gap" ]]; then
  grep -F '"phase":"verifier-step-ready"' "$state_root/state.json" >/dev/null
  grep -F 'fake child builder report before verifier export crash for benchmark-gap' "$state_root/builder-1.json" >/dev/null
  grep -Fx 'preserve-builder-progress' "$workspace_root/preserve-builder-progress.txt" >/dev/null
fi

if [[ "${CLASP_TEST_FAKE_CHILD_DELAY_REPORT_AFTER_EXIT:-0}" == "1" && "$task_id" == "benchmark-gap" ]]; then
  mkdir -p "$state_root"
  cat >"$state_root/state.json" <<'JSON'
{"attempt":1,"phase":"completed","verdict":"pass","completed":true,"builderRuns":1,"verifierRuns":1,"healthy":true,"needsAttention":false,"attentionReason":"","final":true}
JSON
  nohup bash -c '
    set -euo pipefail
    state_root="$1"
    sleep "${CLASP_TEST_FAKE_CHILD_DELAY_REPORT_SECS:-0.2}"
    cat >"$state_root/feedback.json" <<'"'"'JSON'"'"'
{"verdict":"pass","summary":"fake child loop completed after report settle","findings":[],"tests_run":["fake delayed child loop"],"follow_up":[],"capability_statuses":[]}
JSON
  ' delayed-child-report "$state_root" >/dev/null 2>&1 &
  printf 'fake child exited before durable report became visible\n'
  exit 0
fi

if [[ "${CLASP_TEST_FAKE_CHILD_FAIL_FIRST_WAVE:-0}" == "1" && "$task_id" == "benchmark-gap" ]]; then
  mkdir -p "$state_root"
  cat >"$state_root/state.json" <<'JSON'
{"attempt":1,"phase":"failed","verdict":"fail","completed":false,"builderRuns":1,"verifierRuns":1,"healthy":false,"needsAttention":true,"attentionReason":"fake first wave failed","final":true}
JSON
  cat >"$state_root/feedback.json" <<'JSON'
{"verdict":"fail","summary":"fake first wave failed","findings":["first wave intentionally failed"],"tests_run":["fake child loop"],"follow_up":["plan a different wave"],"capability_statuses":[]}
JSON
  printf 'fake child loop failed first wave\n'
  exit 0
fi

if [[ -n "$workspace_root" ]]; then
  content="fixed-after-feedback"
  if [[ "${CLASP_TEST_FAKE_PROMOTION_CONFLICT:-0}" == "1" ]]; then
    content="fixed-after-feedback-$task_id"
  fi
  mkdir -p "$workspace_root/notes" "$workspace_root/.clasp-test-tmp"
  printf '%s\n' "$content" >"$workspace_root/workspace.txt"
  printf '%s\n' "$content" >"$workspace_root/notes/child-artifact.txt"
  printf '%s\n' 'transient-noise' >"$workspace_root/.clasp-test-tmp/noise.txt"
  if [[ "${CLASP_TEST_FAKE_CHILD_CORRUPT_WORKSPACE_MANIFEST:-0}" == "1" ]]; then
    printf '%s\n' '{"kind":"clasp-task-workspace","manifestVersion":1,"taskId":"wrong-task","snapshotPolicyId":"wrong-policy"}' >"$workspace_root/.clasp-task-workspace-manifest.json"
  fi
fi

if [[ -n "${CLASP_TEST_FAKE_CHILD_SLEEP_SECS:-}" ]]; then
  sleep "$CLASP_TEST_FAKE_CHILD_SLEEP_SECS"
fi

mkdir -p "$state_root"
cat >"$state_root/state.json" <<'JSON'
{"attempt":1,"phase":"completed","verdict":"pass","completed":true,"builderRuns":1,"verifierRuns":1,"healthy":true,"needsAttention":false,"attentionReason":"","final":true}
JSON
if [[ "${CLASP_TEST_FAKE_CHILD_WRITE_BUILDER_REPORT:-0}" == "1" ]]; then
  cat >"$state_root/builder-1.json" <<JSON
{"summary":"fake child builder report for $task_id","files_touched":["workspace.txt","notes/child-artifact.txt"],"tests_run":["fake child builder"],"residual_risks":["verify mailbox reuse"],"feedback":{"summary":"builder mailbox details for $task_id","ergonomics":["ordinary loop state stays durable"],"follow_ups":["reuse mailbox context for $task_id"],"warnings":[]}}
JSON
fi
cat >"$state_root/feedback.json" <<JSON
{"verdict":"pass","summary":"fake child loop completed","findings":["carry-forward finding for $task_id"],"tests_run":["fake child loop"],"follow_up":["reuse mailbox context for $task_id"],"capability_statuses":[{"name":"ordinary_program_execution","status":"pass","evidence":["fake child loop completed"],"blocking_gaps":[],"required_closure":[]}]}
JSON
printf 'fake child loop completed\n'
EOF
chmod +x "$fake_child_claspc_bin"

cat >"$fake_passing_benchmark_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${CLASP_MANAGER_BENCHMARK_WAVE:-}" != "1" ]]; then
  printf 'unexpected benchmark wave: %s\n' "${CLASP_MANAGER_BENCHMARK_WAVE:-}" >&2
  exit 2
fi
if [[ "${CLASP_MANAGER_BENCHMARK_RUNS:-}" != "0" ]]; then
  printf 'unexpected benchmark run count: %s\n' "${CLASP_MANAGER_BENCHMARK_RUNS:-}" >&2
  exit 2
fi

cat <<'JSON'
{"suite":"appbench","summary":"wave 1 benchmark meets target.","passed":true,"meetsTarget":true,"scoreName":"timeToGreenMs","scoreValue":100,"targetName":"maxTimeToGreenMs","targetValue":120}
JSON
EOF
chmod +x "$fake_passing_benchmark_bin"

cat >"$fake_slow_benchmark_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

sleep "${CLASP_TEST_FAKE_BENCHMARK_SLEEP_SECS:-1}"
printf 'fake benchmark log before signal\n'
cat <<'JSON'
{"suite":"appbench","summary":"slow benchmark eventually finished.","passed":true,"meetsTarget":true,"scoreName":"timeToGreenMs","scoreValue":100,"targetName":"maxTimeToGreenMs","targetValue":120}
JSON
EOF
chmod +x "$fake_slow_benchmark_bin"

cat >"$fake_replan_benchmark_bin" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

wave="${CLASP_MANAGER_BENCHMARK_WAVE:-1}"
if [[ "$wave" == "1" ]]; then
  cat <<'JSON'
{"suite":"appbench","summary":"wave 1 benchmark still misses target.","passed":true,"meetsTarget":false,"scoreName":"timeToGreenMs","scoreValue":140,"targetName":"maxTimeToGreenMs","targetValue":120}
JSON
else
  cat <<'JSON'
{"suite":"appbench","summary":"wave 2 benchmark meets target.","passed":true,"meetsTarget":true,"scoreName":"timeToGreenMs","scoreValue":100,"targetName":"maxTimeToGreenMs","targetValue":120}
JSON
fi
EOF
chmod +x "$fake_replan_benchmark_bin"

if [[ -n "${CLASP_GOAL_MANAGER_BINARY:-}" ]]; then
  if [[ ! -x "$goal_manager_binary" ]]; then
    echo "CLASP_GOAL_MANAGER_BINARY is not executable: $goal_manager_binary" >&2
    exit 1
  fi
  goal_manager_actual_binary="$goal_manager_binary"
else
  mkdir -p "$goal_manager_build_cache_dir" "$goal_manager_build_xdg_cache_home"
  goal_manager_ensure_stderr="$test_root_abs/ensure-goal-manager.stderr"
  if ! XDG_CACHE_HOME="$goal_manager_build_xdg_cache_home" \
      CLASP_GOAL_MANAGER_CACHE_DIR="$goal_manager_build_cache_dir" \
      "$project_root/scripts/ensure-goal-manager-binary.sh" \
      --alias "$goal_manager_live_binary" \
      --alias "$goal_manager_actual_binary" \
      >/dev/null 2>"$goal_manager_ensure_stderr"; then
    sed -n '1,120p' "$goal_manager_ensure_stderr" >&2 || true
    exit 1
  fi
  sed -n '1,120p' "$goal_manager_ensure_stderr" >&2 || true
  if grep -F 'using stale goal manager binary' "$goal_manager_ensure_stderr" >/dev/null 2>&1; then
    goal_manager_binary_fresh=0
  fi
  goal_manager_binary="$goal_manager_live_binary"
fi

split_goal_manager_binary="$goal_manager_binary"

run_manager_binary() {
  local binary_path="$1"
  local state_root="$2"
  local workspace_root="$3"
  local output_path
  local run_status=0
  shift 3

  output_path="$(mktemp "$test_root_abs/run-manager-output.XXXXXX")"
  if env \
    -u CLASP_MANAGER_PROJECT_ROOT_JSON \
    -u CLASP_MANAGER_READY_PATH_JSON \
    -u CLASP_MANAGER_READY_TEXT_JSON \
    -u CLASP_MANAGER_SERVICE_ID_JSON \
    -u CLASP_MANAGER_SERVICE_ROOT_JSON \
    -u CLASP_MANAGER_XDG_CACHE_HOME_JSON \
    -u CLASP_RT_CURRENT_EXECUTABLE_PATH_JSON \
    -u CLASP_RT_SERVICE_GENERATION_JSON \
    -u CLASP_RT_SERVICE_ID_JSON \
    -u CLASP_RT_SERVICE_ROOT_JSON \
    -u CLASP_RT_SERVICE_SUPERVISED_JSON \
    XDG_CACHE_HOME="$state_root/host-xdg-cache" \
    CLASP_TEST_FAKE_CODEX_SLEEP_SECS="${CLASP_TEST_FAKE_CODEX_SLEEP_SECS:-0.05}" \
    CLASP_LOOP_CODEX_BIN_JSON="\"$fake_codex_bin\"" \
    CLASP_LOOP_WORKSPACE_JSON="\"$workspace_root\"" \
    CLASP_MANAGER_CLASPC_BIN_JSON="\"$fake_child_claspc_bin\"" \
    CLASP_MANAGER_GOAL_JSON='"Beat the AppBench target for Clasp."' \
    CLASP_MANAGER_OBJECTIVE_ID_JSON='"improve-clasp"' \
    CLASP_MANAGER_MAX_TASKS_JSON='1' \
    CLASP_MANAGER_MAX_WAVES_JSON='1' \
    CLASP_LOOP_WATCH_POLL_MS_JSON='50' \
    "$@" \
    "$binary_path" "$state_root" \
    >"$output_path" 2>&1; then
    cat "$output_path"
    rm -f "$output_path"
    return 0
  else
    run_status=$?
  fi

  if grep -F 'runtime failed to execute native compiler export' "$output_path" >/dev/null 2>&1 &&
      [[ -f "$state_root/status.json" ]] &&
      grep -F '"final":true' "$state_root/status.json" >/dev/null 2>&1; then
    cat "$state_root/status.json"
    rm -f "$output_path"
    return 0
  fi

  cat "$output_path"
  rm -f "$output_path"
  return "$run_status"
}

run_goal_manager() {
  local state_root="$1"
  local workspace_root="$2"
  shift 2
  run_manager_binary "$goal_manager_binary" "$state_root" "$workspace_root" "$@"
}

run_actual_goal_manager() {
  local state_root="$1"
  local workspace_root="$2"
  shift 2
  run_manager_binary "$goal_manager_actual_binary" "$state_root" "$workspace_root" "$@"
}

run_split_goal_manager() {
  local state_root="$1"
  local workspace_root="$2"
  shift 2
  run_manager_binary "$split_goal_manager_binary" "$state_root" "$workspace_root" "$@"
}

run_goal_manager_status_with_binary() {
  local binary_path="$1"
  local state_root="$2"
  local workspace_root="$3"
  shift 3
  env \
    -u CLASP_MANAGER_PROJECT_ROOT_JSON \
    -u CLASP_MANAGER_READY_PATH_JSON \
    -u CLASP_MANAGER_READY_TEXT_JSON \
    -u CLASP_MANAGER_SERVICE_ID_JSON \
    -u CLASP_MANAGER_SERVICE_ROOT_JSON \
    -u CLASP_MANAGER_XDG_CACHE_HOME_JSON \
    -u CLASP_RT_CURRENT_EXECUTABLE_PATH_JSON \
    -u CLASP_RT_SERVICE_GENERATION_JSON \
    -u CLASP_RT_SERVICE_ID_JSON \
    -u CLASP_RT_SERVICE_ROOT_JSON \
    -u CLASP_RT_SERVICE_SUPERVISED_JSON \
    XDG_CACHE_HOME="$state_root/host-xdg-cache" \
    CLASP_TEST_FAKE_CODEX_SLEEP_SECS="${CLASP_TEST_FAKE_CODEX_SLEEP_SECS:-0.05}" \
    CLASP_LOOP_CODEX_BIN_JSON="\"$fake_codex_bin\"" \
    CLASP_LOOP_WORKSPACE_JSON="\"$workspace_root\"" \
    CLASP_MANAGER_CLASPC_BIN_JSON="\"$fake_child_claspc_bin\"" \
    CLASP_MANAGER_GOAL_JSON='"Beat the AppBench target for Clasp."' \
    CLASP_MANAGER_OBJECTIVE_ID_JSON='"improve-clasp"' \
    CLASP_MANAGER_MAX_TASKS_JSON='1' \
    CLASP_MANAGER_MAX_WAVES_JSON='1' \
    CLASP_LOOP_WATCH_POLL_MS_JSON='50' \
    CLASP_MANAGER_COMMAND='status' \
    "$@" \
    "$binary_path" "$state_root"
}

run_goal_manager_status() {
  local state_root="$1"
  local workspace_root="$2"
  shift 2
  run_goal_manager_status_with_binary "$goal_manager_binary" "$state_root" "$workspace_root" "$@"
}

run_actual_goal_manager_status() {
  local state_root="$1"
  local workspace_root="$2"
  shift 2
  run_goal_manager_status_with_binary "$goal_manager_actual_binary" "$state_root" "$workspace_root" "$@"
}

run_split_goal_manager_status() {
  local state_root="$1"
  local workspace_root="$2"
  shift 2
  run_goal_manager_status_with_binary "$split_goal_manager_binary" "$state_root" "$workspace_root" "$@"
}

run_task_workspace_harness() {
  local state_root="$1"
  local workspace_root="$2"
  local task_workspace_base="$3"
  local mode="${4:-ensure}"
  local task_id="${5:-benchmark-gap}"

  env \
    XDG_CACHE_HOME="$goal_manager_build_xdg_cache_home" \
    CLASP_LOOP_WORKSPACE_JSON="\"$workspace_root\"" \
    CLASP_MANAGER_TASK_WORKSPACE_ROOT_JSON="\"$task_workspace_base\"" \
    CLASP_TASK_WORKSPACE_HARNESS_TASK_ID_JSON="\"$task_id\"" \
    CLASP_TASK_WORKSPACE_HARNESS_MODE_JSON="\"$mode\"" \
    "$claspc_bin" run "$project_root/examples/swarm-native/TaskWorkspaceRuntimeHarness.clasp" -- "$state_root"
}

if [[ "${CLASP_GOAL_MANAGER_FAST_STATUS_ONLY:-0}" != "1" ]]; then
trace_case "safe-manager-workspace-root-fallback"
safe_root_state="$test_root_abs/safe-root-state"
safe_root_output="$test_root_abs/safe-root-output.txt"
safe_root_manifest="$safe_root_state/manager-workspace/.clasp-manager-workspace-manifest.json"
safe_root_agents_hash_before="$(sha256sum "$project_root/AGENTS.md" | awk '{print $1}')"
safe_root_workspace_hash_before="$(sha256sum "$project_root/workspace.txt" | awk '{print $1}')"
safe_root_goal_manager_hash_before="$(sha256sum "$project_root/examples/swarm-native/GoalManager.clasp" | awk '{print $1}')"
safe_root_project_ready_hash_before="$(file_hash_or_missing "$project_root/.clasp-manager-workspace-ready")"
safe_root_project_manifest_hash_before="$(file_hash_or_missing "$project_root/.clasp-manager-workspace-manifest.json")"
(
  cd "$project_root"
  run_actual_goal_manager "$safe_root_state" "." \
    CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
    CLASP_MANAGER_MAX_WAVES_JSON='1' \
    >"$safe_root_output" 2>&1
)
grep -F '"phase":"completed"' "$safe_root_output" >/dev/null
grep -F '"verdict":"pass"' "$safe_root_output" >/dev/null
if grep -F 'workspace-root-error' "$safe_root_output" "$safe_root_state/status.json" "$safe_root_state/feedback.json" >/dev/null 2>&1; then
  echo "manager reported workspace-root-error for project-root workspace fallback" >&2
  sed -n '1,120p' "$safe_root_output" >&2 || true
  exit 1
fi
test -f "$safe_root_state/status.json"
test -f "$safe_root_state/service.ready"
test -f "$safe_root_state/manager-workspace/.clasp-manager-workspace-ready"
test -f "$safe_root_manifest"
node - "$safe_root_manifest" "$project_root" "$safe_root_state/manager-workspace" <<'NODE'
const fs = require('fs');
const manifestPath = process.argv[2];
const expectedProjectRoot = fs.realpathSync(process.argv[3]);
const expectedWorkspaceRoot = fs.realpathSync(process.argv[4]);
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
if (manifest.kind !== 'clasp-manager-workspace') {
  throw new Error(`unexpected manifest kind: ${manifest.kind}`);
}
if (manifest.workspaceRoot !== '.') {
  throw new Error(`expected requested workspace '.', got ${manifest.workspaceRoot}`);
}
if (manifest.projectRoot !== expectedProjectRoot) {
  throw new Error(`expected projectRoot ${expectedProjectRoot}, got ${manifest.projectRoot}`);
}
if (manifest.actualWorkspaceRoot !== expectedWorkspaceRoot) {
  throw new Error(`expected actualWorkspaceRoot ${expectedWorkspaceRoot}, got ${manifest.actualWorkspaceRoot}`);
}
NODE
[[ "$(file_hash_or_missing "$project_root/.clasp-manager-workspace-ready")" == "$safe_root_project_ready_hash_before" ]]
[[ "$(file_hash_or_missing "$project_root/.clasp-manager-workspace-manifest.json")" == "$safe_root_project_manifest_hash_before" ]]
[[ "$(sha256sum "$project_root/AGENTS.md" | awk '{print $1}')" == "$safe_root_agents_hash_before" ]]
[[ "$(sha256sum "$project_root/workspace.txt" | awk '{print $1}')" == "$safe_root_workspace_hash_before" ]]
[[ "$(sha256sum "$project_root/examples/swarm-native/GoalManager.clasp" | awk '{print $1}')" == "$safe_root_goal_manager_hash_before" ]]

trace_case "benchmark-resume-noisy-stdout"
benchmark_resume_state="$test_root_abs/benchmark-resume-state"
benchmark_resume_workspace="$test_root_abs/benchmark-resume-workspace"
benchmark_resume_output="$test_root_abs/benchmark-resume-output.txt"
mkdir -p "$benchmark_resume_workspace"

run_actual_goal_manager "$benchmark_resume_state" "$benchmark_resume_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_BENCHMARK_SLEEP_SECS='1' \
  CLASP_MANAGER_MAX_WAVES_JSON='2' \
  CLASP_MANAGER_BENCHMARK_COMMAND_JSON="[\"$fake_slow_benchmark_bin\"]" \
  >"$benchmark_resume_output.first" 2>&1 &
goal_manager_live_pid=$!

wait_for_path_contains "$benchmark_resume_state/status.json" '"phase":"benchmark-running"' "" 1200 0.05
wait_for_path_contains "$benchmark_resume_state/benchmark-1.heartbeat.json" '"running":true' "" 600 0.05
stop_goal_manager_service "$benchmark_resume_state"
wait_or_kill_pid "$goal_manager_live_pid" 100
goal_manager_live_pid=""

run_actual_goal_manager "$benchmark_resume_state" "$benchmark_resume_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_BENCHMARK_SLEEP_SECS='1' \
  CLASP_MANAGER_MAX_WAVES_JSON='2' \
  CLASP_MANAGER_BENCHMARK_COMMAND_JSON="[\"$fake_slow_benchmark_bin\"]" \
  >"$benchmark_resume_output.second" 2>&1 &
goal_manager_live_pid=$!
wait_for_path_contains "$benchmark_resume_state/status.json" '"phase":"completed"' "" 1200 0.05
wait_or_kill_pid "$goal_manager_live_pid" 100
goal_manager_live_pid=""
benchmark_resume_result="$(
  run_actual_goal_manager_status "$benchmark_resume_state" "$benchmark_resume_workspace" \
    CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
    CLASP_TEST_FAKE_BENCHMARK_SLEEP_SECS='1' \
    CLASP_MANAGER_MAX_WAVES_JSON='2' \
    CLASP_MANAGER_BENCHMARK_COMMAND_JSON="[\"$fake_slow_benchmark_bin\"]"
)"
printf '%s\n' "$benchmark_resume_result" >"$benchmark_resume_output"
grep -F '"phase":"completed"' "$benchmark_resume_output" >/dev/null
grep -F '"verdict":"pass"' "$benchmark_resume_output" >/dev/null
grep -F '"benchmarkTargetMet":true' "$benchmark_resume_output" >/dev/null
grep -F '"summary":"slow benchmark eventually finished."' "$benchmark_resume_state/benchmark-1.json" >/dev/null
grep -F 'fake benchmark log before signal' "$benchmark_resume_state/benchmark-1.stdout.txt" >/dev/null
grep -Fx 'fixed-after-feedback' "$benchmark_resume_workspace/workspace.txt" >/dev/null
grep -Fx 'fixed-after-feedback' "$benchmark_resume_workspace/notes/child-artifact.txt" >/dev/null
test ! -e "$benchmark_resume_workspace/.clasp-test-tmp/noise.txt"

trace_case "benchmark-checkpoint-pass-status"
benchmark_pass_state="$test_root_abs/benchmark-pass-state"
benchmark_pass_workspace="$test_root_abs/benchmark-pass-workspace"
benchmark_pass_output="$test_root_abs/benchmark-pass-output.txt"
benchmark_pass_status="$test_root_abs/benchmark-pass-status.json"
mkdir -p "$benchmark_pass_workspace"
run_actual_goal_manager "$benchmark_pass_state" "$benchmark_pass_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  CLASP_MANAGER_BENCHMARK_COMMAND_JSON="[\"$fake_passing_benchmark_bin\"]" \
  >"$benchmark_pass_output" 2>&1
benchmark_pass_status_result="$(
  run_actual_goal_manager_status "$benchmark_pass_state" "$benchmark_pass_workspace" \
    CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
    CLASP_MANAGER_MAX_WAVES_JSON='1' \
    CLASP_MANAGER_BENCHMARK_COMMAND_JSON="[\"$fake_passing_benchmark_bin\"]"
)"
printf '%s\n' "$benchmark_pass_status_result" >"$benchmark_pass_status"
test -f "$benchmark_pass_state/benchmark-1.json"
test -f "$benchmark_pass_state/benchmark-latest.json"
node - "$benchmark_pass_status" "$benchmark_pass_state/benchmark-1.json" "$benchmark_pass_state/benchmark-latest.json" <<'NODE'
const fs = require('fs');
const [statusPath, checkpointPath, latestPath] = process.argv.slice(2);
const status = JSON.parse(fs.readFileSync(statusPath, 'utf8'));
const checkpoint = JSON.parse(fs.readFileSync(checkpointPath, 'utf8'));
const latest = JSON.parse(fs.readFileSync(latestPath, 'utf8'));

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

assert(status.state.phase === 'completed', `expected completed phase, got ${status.state.phase}`);
assert(status.state.verdict === 'pass', `expected pass verdict, got ${status.state.verdict}`);
assert(status.state.completed === true, 'expected completed=true');
assert(status.state.final === true, 'expected final=true');
assert(status.state.benchmarkRuns === 1, `expected benchmarkRuns=1, got ${status.state.benchmarkRuns}`);
assert(status.benchmarkTargetMet === true, 'expected status benchmarkTargetMet=true');
assert(status.benchmarkSummary === 'wave 1 benchmark meets target.', `unexpected benchmark summary: ${status.benchmarkSummary}`);
for (const [label, value] of [['benchmark-1', checkpoint], ['benchmark-latest', latest]]) {
  assert(value.wave === 1, `${label} expected wave=1, got ${value.wave}`);
  assert(value.suite === 'appbench', `${label} expected suite=appbench, got ${value.suite}`);
  assert(value.meetsTarget === true, `${label} expected meetsTarget=true`);
  assert(value.summary === 'wave 1 benchmark meets target.', `${label} unexpected summary: ${value.summary}`);
}
assert(JSON.stringify(checkpoint) === JSON.stringify(latest), 'latest checkpoint should match benchmark-1');
NODE
fi

trace_case "status-waiting-reasons-dependency-blocked"
dependency_status_state="$test_root_abs/dependency-status-state"
dependency_status_workspace="$test_root_abs/dependency-status-workspace"
dependency_status_output="$test_root_abs/dependency-status-output.json"
mkdir -p "$dependency_status_workspace"
"$claspc_bin" --json swarm objective create "$dependency_status_state" improve-clasp --max-tasks 64 --max-runs 64 >/dev/null
"$claspc_bin" --json swarm task create "$dependency_status_state" improve-clasp prep --max-runs 1 --lease-timeout-ms 3600000 >/dev/null
"$claspc_bin" --json swarm task create "$dependency_status_state" improve-clasp ship --depends-on prep --max-runs 1 --lease-timeout-ms 3600000 >/dev/null
"$claspc_bin" --json swarm lease "$dependency_status_state" prep >/dev/null
cat >"$dependency_status_state/status.json" <<'JSON'
{"phase":"task-running","verdict":"pending","completed":false,"objectiveId":"improve-clasp","plannerTaskId":"planner","activeTaskId":"","plannedTaskIds":["ship"],"wave":1,"benchmarkRuns":0,"final":false}
JSON
dependency_status_result="$(run_actual_goal_manager_status "$dependency_status_state" "$dependency_status_workspace" CLASP_MANAGER_MAX_WAVES_JSON='1')"
printf '%s\n' "$dependency_status_result" >"$dependency_status_output"
node - "$dependency_status_output" <<'NODE'
const fs = require('fs');
const value = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (value.primaryWaitingReason !== 'task-dependencies') {
  throw new Error(`expected task-dependencies primary reason, got ${value.primaryWaitingReason}`);
}
if (!Array.isArray(value.primaryWaitingTaskIds) || !value.primaryWaitingTaskIds.includes('ship')) {
  throw new Error(`expected ship in primaryWaitingTaskIds: ${JSON.stringify(value.primaryWaitingTaskIds)}`);
}
const dependencyReason = Array.isArray(value.waitingReasons)
  ? value.waitingReasons.find((reason) => reason.kind === 'task-dependencies')
  : null;
if (!dependencyReason) {
  throw new Error(`missing task-dependencies waiting reason: ${JSON.stringify(value.waitingReasons)}`);
}
if (!Array.isArray(dependencyReason.taskIds) || !dependencyReason.taskIds.includes('ship')) {
  throw new Error(`expected ship in dependency reason taskIds: ${JSON.stringify(dependencyReason)}`);
}
if (!Array.isArray(dependencyReason.relatedTaskIds) || !dependencyReason.relatedTaskIds.includes('prep')) {
  throw new Error(`expected prep in dependency reason relatedTaskIds: ${JSON.stringify(dependencyReason)}`);
}
NODE

trace_case "status-waiting-reasons-benchmark-running"
benchmark_status_state="$test_root_abs/benchmark-status-state"
benchmark_status_workspace="$test_root_abs/benchmark-status-workspace"
benchmark_status_output="$test_root_abs/benchmark-status-output.json"
mkdir -p "$benchmark_status_workspace"
"$claspc_bin" --json swarm objective create "$benchmark_status_state" improve-clasp --max-tasks 64 --max-runs 64 >/dev/null
"$claspc_bin" --json swarm task create "$benchmark_status_state" improve-clasp benchmark-gap --max-runs 1 --lease-timeout-ms 3600000 >/dev/null
cat >"$benchmark_status_state/status.json" <<'JSON'
{"phase":"benchmark-running","verdict":"pending","completed":false,"objectiveId":"improve-clasp","plannerTaskId":"planner","activeTaskId":"","plannedTaskIds":["benchmark-gap"],"wave":1,"benchmarkRuns":0,"final":false}
JSON
cat >"$benchmark_status_state/planner-1.json" <<'JSON'
{"objectiveSummary":"Reduce the AppBench gap with an initial wave.","strategy":"Run one bounded task before re-checking the benchmark.","tasks":[{"taskId":"benchmark-gap","role":"benchmark-operator","detail":"Close the benchmark gap.","dependencies":[],"taskPrompt":"Run the bounded benchmark improvement wave.","coordinationFocus":["baseline-gap"]}],"testsRun":["benchmark-status"],"residualRisks":[]}
JSON
benchmark_status_result="$(run_actual_goal_manager_status "$benchmark_status_state" "$benchmark_status_workspace" CLASP_MANAGER_MAX_WAVES_JSON='1')"
printf '%s\n' "$benchmark_status_result" >"$benchmark_status_output"
node - "$benchmark_status_output" <<'NODE'
const fs = require('fs');
const value = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (value.primaryWaitingReason !== 'benchmark-execution') {
  throw new Error(`expected benchmark-execution primary reason, got ${value.primaryWaitingReason}`);
}
if (!Array.isArray(value.primaryWaitingTaskIds) || !value.primaryWaitingTaskIds.includes('benchmark-gap')) {
  throw new Error(`expected benchmark-gap in primaryWaitingTaskIds: ${JSON.stringify(value.primaryWaitingTaskIds)}`);
}
const benchmarkReason = Array.isArray(value.waitingReasons)
  ? value.waitingReasons.find((reason) => reason.kind === 'benchmark-execution')
  : null;
if (!benchmarkReason) {
  throw new Error(`missing benchmark-execution waiting reason: ${JSON.stringify(value.waitingReasons)}`);
}
if (!Array.isArray(benchmarkReason.taskIds) || !benchmarkReason.taskIds.includes('benchmark-gap')) {
  throw new Error(`expected benchmark-gap in benchmark reason taskIds: ${JSON.stringify(benchmarkReason)}`);
}
NODE

if [[ "${CLASP_GOAL_MANAGER_FAST_STATUS_ONLY:-0}" != "1" ]]; then
trace_case "empty-policy-env-falls-back-to-policy-file"
empty_policy_state="$test_root_abs/empty-policy-state"
empty_policy_workspace="$test_root_abs/empty-policy-workspace"
empty_policy_output="$test_root_abs/empty-policy-output.txt"
mkdir -p "$empty_policy_state" "$empty_policy_workspace"
cat >"$empty_policy_state/planner-policy.md" <<'EOF'
Prefer file-backed policy when the JSON env override is empty.
EOF
run_goal_manager "$empty_policy_state" "$empty_policy_workspace" \
  CLASP_MANAGER_PLANNER_POLICY_JSON='' \
  >"$empty_policy_output" 2>&1
grep -F '"phase":"completed"' "$empty_policy_output" >/dev/null
grep -F '"verdict":"pass"' "$empty_policy_output" >/dev/null
grep -F '"plannerPolicy":"Prefer file-backed policy when the JSON env override is empty.' "$empty_policy_state/planner-input.json" >/dev/null

trace_case "split-mailbox-summary-resume"
split_mailbox_state="$test_root_abs/split-mailbox-state"
split_mailbox_workspace="$test_root_abs/split-mailbox-workspace"
split_mailbox_output="$test_root_abs/split-mailbox-output.txt"
mkdir -p "$split_mailbox_workspace"

run_split_goal_manager "$split_mailbox_state" "$split_mailbox_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_CHILD_WRITE_BUILDER_REPORT='1' \
  CLASP_TEST_FAKE_PLANNER_WAVE2_SLEEP_SECS='1' \
  CLASP_MANAGER_MAX_WAVES_JSON='2' \
  CLASP_MANAGER_BENCHMARK_COMMAND_JSON="[\"$fake_replan_benchmark_bin\"]" \
  >"$split_mailbox_output.first" 2>&1 &
goal_manager_live_pid=$!
wait_for_path_contains "$split_mailbox_state/status.json" '"phase":"planner-running"' "" 1200 0.05
wait_for_path_contains "$split_mailbox_state/status.json" '"wave":2' "" 1200 0.05
stop_goal_manager_service "$split_mailbox_state"
wait_or_kill_pid "$goal_manager_live_pid" 100
goal_manager_live_pid=""

run_split_goal_manager "$split_mailbox_state" "$split_mailbox_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_CHILD_WRITE_BUILDER_REPORT='1' \
  CLASP_TEST_EXPECT_WAVE2_MAILBOX='1' \
  CLASP_MANAGER_MAX_WAVES_JSON='2' \
  CLASP_MANAGER_BENCHMARK_COMMAND_JSON="[\"$fake_replan_benchmark_bin\"]" \
  >"$split_mailbox_output.second" 2>&1
grep -F '"phase":"completed"' "$split_mailbox_output.second" >/dev/null
grep -F '"verdict":"pass"' "$split_mailbox_output.second" >/dev/null
grep -F 'fake child builder report for benchmark-gap' "$split_mailbox_state/planner-input.json" >/dev/null
grep -F 'finding=carry-forward finding for benchmark-gap' "$split_mailbox_state/planner-input.json" >/dev/null
grep -F 'follow-up=reuse mailbox context for benchmark-gap' "$split_mailbox_state/planner-input.json" >/dev/null
grep -F '"summary":"fake child builder report for benchmark-gap"' "$split_mailbox_state/mailbox.json" >/dev/null
grep -F 'carry-forward finding for benchmark-gap' "$split_mailbox_state/mailbox.json" >/dev/null

trace_case "planner-health-and-focused-verification-tier"
tiered_state="$test_root_abs/tiered-state"
tiered_workspace="$test_root_abs/tiered-workspace"
tiered_output="$test_root_abs/tiered-output.txt"
mkdir -p "$tiered_workspace"
run_goal_manager "$tiered_state" "$tiered_workspace" \
  CLASP_TEST_EXPECT_PLANNER_HEALTH='1' \
  CLASP_TEST_EXPECT_PLANNER_NO_BROAD_VERIFY='1' \
  CLASP_TEST_EXPECT_FOCUSED_VERIFY_TIER='1' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$tiered_output" 2>&1
grep -F '"phase":"completed"' "$tiered_output" >/dev/null
grep -F '"verdict":"pass"' "$tiered_output" >/dev/null

trace_case "failed-task-replans-next-wave"
failed_replan_state="$test_root_abs/failed-replan-state"
failed_replan_workspace="$test_root_abs/failed-replan-workspace"
failed_replan_output="$test_root_abs/failed-replan-output.txt"
mkdir -p "$failed_replan_workspace"
run_goal_manager "$failed_replan_state" "$failed_replan_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_CHILD_FAIL_FIRST_WAVE='1' \
  CLASP_MANAGER_MAX_WAVES_JSON='2' \
  >"$failed_replan_output" 2>&1
grep -F '"phase":"completed"' "$failed_replan_output" >/dev/null
grep -F '"verdict":"pass"' "$failed_replan_output" >/dev/null
grep -F '"wave":2' "$failed_replan_state/status.json" >/dev/null
grep -F '"plannerTaskId":"planner-2"' "$failed_replan_state/status.json" >/dev/null
grep -F '"summary":"fake first wave failed"' "$failed_replan_state/loop-benchmark-gap/feedback.json" >/dev/null
test -f "$failed_replan_state/planner-2.json"
grep -F '"wave-2-benchmark-gap"' "$failed_replan_state/status.json" >/dev/null
grep -Fx 'fixed-after-feedback' "$failed_replan_workspace/workspace.txt" >/dev/null

trace_case "failed-task-does-not-benchmark-pass"
failed_benchmark_state="$test_root_abs/failed-benchmark-state"
failed_benchmark_workspace="$test_root_abs/failed-benchmark-workspace"
failed_benchmark_output="$test_root_abs/failed-benchmark-output.txt"
mkdir -p "$failed_benchmark_workspace"
run_goal_manager "$failed_benchmark_state" "$failed_benchmark_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_CHILD_FAIL_FIRST_WAVE='1' \
  CLASP_MANAGER_MAX_WAVES_JSON='2' \
  CLASP_MANAGER_BENCHMARK_COMMAND_JSON="[\"$fake_slow_benchmark_bin\"]" \
  >"$failed_benchmark_output" 2>&1
grep -F '"phase":"completed"' "$failed_benchmark_output" >/dev/null
grep -F '"verdict":"pass"' "$failed_benchmark_output" >/dev/null
grep -F '"wave":2' "$failed_benchmark_state/status.json" >/dev/null
grep -F '"benchmarkRuns":1' "$failed_benchmark_state/status.json" >/dev/null
test ! -f "$failed_benchmark_state/benchmark-1.json"
test -f "$failed_benchmark_state/benchmark-2.json"
grep -F '"summary":"fake first wave failed"' "$failed_benchmark_state/loop-benchmark-gap/feedback.json" >/dev/null

trace_case "task-workspace-snapshot-excludes-cache-dirs"
snapshot_exclude_state="$test_root_abs/snapshot-exclude-state"
snapshot_exclude_workspace="$test_root_abs/snapshot-exclude-workspace"
snapshot_exclude_output="$test_root_abs/snapshot-exclude-output.txt"
mkdir -p \
  "$snapshot_exclude_workspace/.clasp-task-workspaces/stale-cache" \
  "$snapshot_exclude_workspace/.clasp-task-baselines/stale-baseline" \
  "$snapshot_exclude_workspace/runtime/target/debug"
printf 'must-not-copy\n' >"$snapshot_exclude_workspace/.clasp-task-workspaces/stale-cache/sentinel.txt"
printf 'must-not-copy\n' >"$snapshot_exclude_workspace/.clasp-task-baselines/stale-baseline/sentinel.txt"
printf 'must-not-copy\n' >"$snapshot_exclude_workspace/runtime/target/debug/sentinel.txt"
run_goal_manager "$snapshot_exclude_state" "$snapshot_exclude_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$snapshot_exclude_output" 2>&1
grep -F '"phase":"completed"' "$snapshot_exclude_output" >/dev/null
grep -F '"verdict":"pass"' "$snapshot_exclude_output" >/dev/null
test -f "$snapshot_exclude_workspace/.clasp-manager-workspace-ready"
grep -F '"kind":"clasp-manager-workspace"' "$snapshot_exclude_workspace/.clasp-manager-workspace-manifest.json" >/dev/null
test -f "$snapshot_exclude_workspace/examples/swarm-native/GoalManager.clasp"
test -d "$snapshot_exclude_workspace/.git"
test -f "$snapshot_exclude_workspace/.clasp-task-workspaces/benchmark-gap/.workspace-ready"
test -d "$snapshot_exclude_workspace/.clasp-task-workspaces/benchmark-gap/.git"
task_workspace_git_root="$(git -C "$snapshot_exclude_workspace/.clasp-task-workspaces/benchmark-gap" rev-parse --show-toplevel)"
[[ "$task_workspace_git_root" == "$snapshot_exclude_workspace/.clasp-task-workspaces/benchmark-gap" ]]
test ! -e "$snapshot_exclude_workspace/.clasp-task-workspaces/benchmark-gap/.clasp-task-workspaces/stale-cache/sentinel.txt"
test ! -e "$snapshot_exclude_workspace/.clasp-task-workspaces/benchmark-gap/.clasp-task-baselines/stale-baseline/sentinel.txt"
test ! -e "$snapshot_exclude_workspace/.clasp-task-workspaces/benchmark-gap/runtime/target/debug/sentinel.txt"
test ! -e "$snapshot_exclude_workspace/.clasp-task-baselines/benchmark-gap/runtime/target/debug/sentinel.txt"

trace_case "task-workspace-stale-symlink-recovery"
stale_symlink_state="$test_root_abs/stale-symlink-state"
stale_symlink_workspace="$test_root_abs/stale-symlink-workspace"
stale_symlink_base="$test_root_abs/stale-symlink-base"
stale_symlink_output="$test_root_abs/stale-symlink-output.txt"
stale_symlink_wrong_target="$test_root_abs/stale-symlink-wrong-target"
stale_symlink_link="$stale_symlink_base/workspace-benchmark-gap"
stale_symlink_actual="$stale_symlink_workspace/.clasp-task-workspaces/benchmark-gap"
stale_symlink_baseline="$stale_symlink_workspace/.clasp-task-baselines/benchmark-gap"
mkdir -p "$stale_symlink_workspace" "$stale_symlink_base" "$stale_symlink_wrong_target"
printf '%s\n' 'ready' >"$stale_symlink_wrong_target/.workspace-ready"
ln -s "$stale_symlink_wrong_target" "$stale_symlink_link"
run_task_workspace_harness "$stale_symlink_state" "$stale_symlink_workspace" "$stale_symlink_base" ensure \
  >"$stale_symlink_output" 2>&1
grep -F 'ok' "$stale_symlink_output" >/dev/null
[[ "$(readlink "$stale_symlink_link")" == "$stale_symlink_actual" ]]
test -f "$stale_symlink_actual/.workspace-ready"
grep -F '"taskId":"benchmark-gap"' "$stale_symlink_actual/.clasp-task-workspace-manifest.json" >/dev/null
grep -F '"actualWorkspaceRoot":'"\"$stale_symlink_actual\"" "$stale_symlink_actual/.clasp-task-workspace-manifest.json" >/dev/null
test -f "$stale_symlink_baseline/.clasp-task-workspace-manifest.json"

trace_case "task-workspace-manifest-mismatch-refusal"
manifest_mismatch_state="$test_root_abs/manifest-mismatch-state"
manifest_mismatch_workspace="$test_root_abs/manifest-mismatch-workspace"
manifest_mismatch_base="$test_root_abs/manifest-mismatch-base"
manifest_mismatch_output="$test_root_abs/manifest-mismatch-output.txt"
mkdir -p "$manifest_mismatch_workspace"
run_task_workspace_harness "$manifest_mismatch_state" "$manifest_mismatch_workspace" "$manifest_mismatch_base" ensure \
  >"$manifest_mismatch_output" 2>&1
manifest_mismatch_actual="$manifest_mismatch_workspace/.clasp-task-workspaces/benchmark-gap"
printf '%s\n' '{"kind":"clasp-task-workspace","manifestVersion":1,"taskId":"wrong-task","snapshotPolicyId":"wrong-policy"}' >"$manifest_mismatch_actual/.clasp-task-workspace-manifest.json"
printf '%s\n' 'fixed-after-feedback' >"$manifest_mismatch_actual/workspace.txt"
run_task_workspace_harness "$manifest_mismatch_state" "$manifest_mismatch_workspace" "$manifest_mismatch_base" promote \
  >"$manifest_mismatch_output" 2>&1
grep -F 'error:task workspace promotion failed' "$manifest_mismatch_output" >/dev/null
grep -F 'manifest validation failed' "$manifest_mismatch_output" >/dev/null
grep -F 'manifest mismatch' "$manifest_mismatch_output" >/dev/null
manifest_mismatch_recoverable_diff="$manifest_mismatch_state/loop-benchmark-gap/promotion-recoverable.diff"
test -f "$manifest_mismatch_recoverable_diff"
grep -F 'manifest mismatch' "$manifest_mismatch_recoverable_diff" >/dev/null
test ! -e "$manifest_mismatch_workspace/workspace.txt"

trace_case "task-workspace-valid-reuse"
valid_reuse_state_one="$test_root_abs/valid-reuse-state-one"
valid_reuse_state_two="$test_root_abs/valid-reuse-state-two"
valid_reuse_workspace="$test_root_abs/valid-reuse-workspace"
valid_reuse_base="$test_root_abs/valid-reuse-base"
valid_reuse_output_one="$test_root_abs/valid-reuse-output-one.txt"
valid_reuse_output_two="$test_root_abs/valid-reuse-output-two.txt"
valid_reuse_actual="$valid_reuse_workspace/.clasp-task-workspaces/benchmark-gap"
valid_reuse_baseline="$valid_reuse_workspace/.clasp-task-baselines/benchmark-gap"
mkdir -p "$valid_reuse_workspace"
run_task_workspace_harness "$valid_reuse_state_one" "$valid_reuse_workspace" "$valid_reuse_base" ensure \
  >"$valid_reuse_output_one" 2>&1
grep -F 'ok' "$valid_reuse_output_one" >/dev/null
printf '%s\n' 'preserve-valid-reuse' >"$valid_reuse_actual/reuse-marker.txt"
printf '%s\n' 'preserve-valid-reuse' >"$valid_reuse_baseline/reuse-marker.txt"
run_task_workspace_harness "$valid_reuse_state_two" "$valid_reuse_workspace" "$valid_reuse_base" ensure \
  >"$valid_reuse_output_two" 2>&1
grep -F 'ok' "$valid_reuse_output_two" >/dev/null
grep -Fx 'preserve-valid-reuse' "$valid_reuse_actual/reuse-marker.txt" >/dev/null
grep -Fx 'preserve-valid-reuse' "$valid_reuse_baseline/reuse-marker.txt" >/dev/null
grep -F '"snapshotPolicyId":"workspace-snapshot-v1:' "$valid_reuse_actual/.clasp-task-workspace-manifest.json" >/dev/null

trace_case "task-workspace-promotion-ledger-disjoint"
promotion_ledger_state="$test_root_abs/promotion-ledger-state"
promotion_ledger_workspace="$test_root_abs/promotion-ledger-workspace"
promotion_ledger_base="$test_root_abs/promotion-ledger-base"
promotion_ledger_output_one="$test_root_abs/promotion-ledger-output-one.txt"
promotion_ledger_output_two="$test_root_abs/promotion-ledger-output-two.txt"
mkdir -p "$promotion_ledger_workspace"
run_task_workspace_harness "$promotion_ledger_state" "$promotion_ledger_workspace" "$promotion_ledger_base" ensure ledger-one \
  >"$promotion_ledger_output_one" 2>&1
run_task_workspace_harness "$promotion_ledger_state" "$promotion_ledger_workspace" "$promotion_ledger_base" ensure ledger-two \
  >"$promotion_ledger_output_two" 2>&1
grep -F 'ok' "$promotion_ledger_output_one" >/dev/null
grep -F 'ok' "$promotion_ledger_output_two" >/dev/null
printf '%s\n' 'ledger-one-applied' >"$promotion_ledger_workspace/.clasp-task-workspaces/ledger-one/one.txt"
printf '%s\n' 'ledger-two-applied' >"$promotion_ledger_workspace/.clasp-task-workspaces/ledger-two/two.txt"
run_task_workspace_harness "$promotion_ledger_state" "$promotion_ledger_workspace" "$promotion_ledger_base" promote ledger-one \
  >"$promotion_ledger_output_one" 2>&1
run_task_workspace_harness "$promotion_ledger_state" "$promotion_ledger_workspace" "$promotion_ledger_base" promote ledger-two \
  >"$promotion_ledger_output_two" 2>&1
grep -F 'ok' "$promotion_ledger_output_one" >/dev/null
grep -F 'ok' "$promotion_ledger_output_two" >/dev/null
grep -Fx 'ledger-one-applied' "$promotion_ledger_workspace/one.txt" >/dev/null
grep -Fx 'ledger-two-applied' "$promotion_ledger_workspace/two.txt" >/dev/null
node - "$promotion_ledger_state/loop-ledger-one/promotion-ledger.json" "$promotion_ledger_state/loop-ledger-two/promotion-ledger.json" <<'NODE'
const fs = require('fs');
const [onePath, twoPath] = process.argv.slice(2);
function read(path) {
  const ledger = JSON.parse(fs.readFileSync(path, 'utf8'));
  if (ledger.schema !== 'clasp-task-workspace-promotion-ledger-v1') throw new Error(`bad schema in ${path}`);
  if (ledger.status !== 'applied' || ledger.conflicted !== false) throw new Error(`expected applied ledger in ${path}`);
  if (!ledger.baseline?.fingerprint?.startsWith('sha256:')) throw new Error(`missing baseline fingerprint in ${path}`);
  if (!ledger.workspace?.fingerprint?.startsWith('sha256:')) throw new Error(`missing workspace fingerprint in ${path}`);
  if (!ledger.baseline?.manifest?.fingerprint?.startsWith('sha256:')) throw new Error(`missing baseline manifest fingerprint in ${path}`);
  if (!ledger.workspace?.manifest?.fingerprint?.startsWith('sha256:')) throw new Error(`missing workspace manifest fingerprint in ${path}`);
  if (ledger.filesSkippedDueToConflict.length !== 0) throw new Error(`unexpected skipped files in ${path}`);
  return ledger;
}
const one = read(onePath);
const two = read(twoPath);
if (one.taskId !== 'ledger-one' || !one.filesApplied.includes('one.txt')) throw new Error('ledger-one did not record one.txt');
if (two.taskId !== 'ledger-two' || !two.filesApplied.includes('two.txt')) throw new Error('ledger-two did not record two.txt');
if (!one.changesApplied.some((change) => change.path === 'one.txt' && change.action === 'add')) throw new Error('ledger-one did not record one.txt add action');
if (!two.changesApplied.some((change) => change.path === 'two.txt' && change.action === 'add')) throw new Error('ledger-two did not record two.txt add action');
NODE

trace_case "task-workspace-promotion-ledger-disjoint-deletion"
promotion_delete_state="$test_root_abs/promotion-delete-state"
promotion_delete_workspace="$test_root_abs/promotion-delete-workspace"
promotion_delete_base="$test_root_abs/promotion-delete-base"
promotion_delete_output_delete="$test_root_abs/promotion-delete-output-delete.txt"
promotion_delete_output_add="$test_root_abs/promotion-delete-output-add.txt"
mkdir -p "$promotion_delete_workspace"
printf '%s\n' 'delete baseline' >"$promotion_delete_workspace/delete-me.txt"
run_task_workspace_harness "$promotion_delete_state" "$promotion_delete_workspace" "$promotion_delete_base" ensure ledger-delete \
  >"$promotion_delete_output_delete" 2>&1
run_task_workspace_harness "$promotion_delete_state" "$promotion_delete_workspace" "$promotion_delete_base" ensure ledger-delete-add \
  >"$promotion_delete_output_add" 2>&1
grep -F 'ok' "$promotion_delete_output_delete" >/dev/null
grep -F 'ok' "$promotion_delete_output_add" >/dev/null
rm -f "$promotion_delete_workspace/.clasp-task-workspaces/ledger-delete/delete-me.txt"
printf '%s\n' 'disjoint add survives' >"$promotion_delete_workspace/.clasp-task-workspaces/ledger-delete-add/added.txt"
run_task_workspace_harness "$promotion_delete_state" "$promotion_delete_workspace" "$promotion_delete_base" promote ledger-delete-add \
  >"$promotion_delete_output_add" 2>&1
run_task_workspace_harness "$promotion_delete_state" "$promotion_delete_workspace" "$promotion_delete_base" promote ledger-delete \
  >"$promotion_delete_output_delete" 2>&1
grep -F 'ok' "$promotion_delete_output_add" >/dev/null
grep -F 'ok' "$promotion_delete_output_delete" >/dev/null
grep -Fx 'disjoint add survives' "$promotion_delete_workspace/added.txt" >/dev/null
test ! -e "$promotion_delete_workspace/delete-me.txt"
node - "$promotion_delete_state/loop-ledger-delete/promotion-ledger.json" "$promotion_delete_state/loop-ledger-delete-add/promotion-ledger.json" <<'NODE'
const fs = require('fs');
const [deleteLedgerPath, addLedgerPath] = process.argv.slice(2);
const deleteLedger = JSON.parse(fs.readFileSync(deleteLedgerPath, 'utf8'));
const addLedger = JSON.parse(fs.readFileSync(addLedgerPath, 'utf8'));
if (deleteLedger.status !== 'applied' || deleteLedger.conflicted !== false) throw new Error('expected applied deletion ledger');
if (addLedger.status !== 'applied' || addLedger.conflicted !== false) throw new Error('expected applied add ledger');
if (!deleteLedger.filesApplied.includes('delete-me.txt')) throw new Error('deletion ledger missing deleted path');
if (!deleteLedger.changesApplied.some((change) => change.path === 'delete-me.txt' && change.action === 'delete')) throw new Error('deletion ledger missing delete action');
if (!addLedger.changesApplied.some((change) => change.path === 'added.txt' && change.action === 'add')) throw new Error('add ledger missing add action');
if (deleteLedger.filesSkippedDueToConflict.length !== 0) throw new Error('unexpected deletion conflicts');
NODE

trace_case "task-workspace-promotion-ledger-conflict-isolated"
promotion_ledger_conflict_state="$test_root_abs/promotion-ledger-conflict-state"
promotion_ledger_conflict_workspace="$test_root_abs/promotion-ledger-conflict-workspace"
promotion_ledger_conflict_base="$test_root_abs/promotion-ledger-conflict-base"
promotion_ledger_conflict_output_a="$test_root_abs/promotion-ledger-conflict-output-a.txt"
promotion_ledger_conflict_output_b="$test_root_abs/promotion-ledger-conflict-output-b.txt"
mkdir -p "$promotion_ledger_conflict_workspace"
printf '%s\n' 'baseline' >"$promotion_ledger_conflict_workspace/shared.txt"
run_task_workspace_harness "$promotion_ledger_conflict_state" "$promotion_ledger_conflict_workspace" "$promotion_ledger_conflict_base" ensure ledger-conflict-a \
  >"$promotion_ledger_conflict_output_a" 2>&1
run_task_workspace_harness "$promotion_ledger_conflict_state" "$promotion_ledger_conflict_workspace" "$promotion_ledger_conflict_base" ensure ledger-conflict-b \
  >"$promotion_ledger_conflict_output_b" 2>&1
grep -F 'ok' "$promotion_ledger_conflict_output_a" >/dev/null
grep -F 'ok' "$promotion_ledger_conflict_output_b" >/dev/null
printf '%s\n' 'branch-a' >"$promotion_ledger_conflict_workspace/.clasp-task-workspaces/ledger-conflict-a/shared.txt"
printf '%s\n' 'branch-b' >"$promotion_ledger_conflict_workspace/.clasp-task-workspaces/ledger-conflict-b/shared.txt"
printf '%s\n' 'branch-b-unique' >"$promotion_ledger_conflict_workspace/.clasp-task-workspaces/ledger-conflict-b/unique-b.txt"
run_task_workspace_harness "$promotion_ledger_conflict_state" "$promotion_ledger_conflict_workspace" "$promotion_ledger_conflict_base" promote ledger-conflict-a \
  >"$promotion_ledger_conflict_output_a" 2>&1
run_task_workspace_harness "$promotion_ledger_conflict_state" "$promotion_ledger_conflict_workspace" "$promotion_ledger_conflict_base" promote ledger-conflict-b \
  >"$promotion_ledger_conflict_output_b" 2>&1
grep -F 'ok' "$promotion_ledger_conflict_output_a" >/dev/null
grep -F 'error:task workspace promotion failed' "$promotion_ledger_conflict_output_b" >/dev/null
grep -Fx 'branch-a' "$promotion_ledger_conflict_workspace/shared.txt" >/dev/null
grep -Fx 'branch-b-unique' "$promotion_ledger_conflict_workspace/unique-b.txt" >/dev/null
test -f "$promotion_ledger_conflict_state/loop-ledger-conflict-b/promotion-conflict.marker"
test -f "$promotion_ledger_conflict_state/loop-ledger-conflict-b/promotion-recoverable.diff"
node - "$promotion_ledger_conflict_state/loop-ledger-conflict-b/promotion-ledger.json" "$promotion_ledger_conflict_state/loop-ledger-conflict-b/promotion-conflict.marker" "$promotion_ledger_conflict_state/loop-ledger-conflict-b/promotion-recoverable.diff" <<'NODE'
const fs = require('fs');
const [ledgerPath, markerPath, diffPath] = process.argv.slice(2);
const ledger = JSON.parse(fs.readFileSync(ledgerPath, 'utf8'));
if (ledger.schema !== 'clasp-task-workspace-promotion-ledger-v1') throw new Error('bad conflict ledger schema');
if (ledger.taskId !== 'ledger-conflict-b') throw new Error('bad conflict task id');
if (ledger.status !== 'conflict' || ledger.conflicted !== true) throw new Error('expected conflict status');
if (!ledger.filesApplied.includes('unique-b.txt')) throw new Error('conflict ledger did not preserve unique file');
if (!ledger.filesSkippedDueToConflict.includes('shared.txt')) throw new Error('conflict ledger did not isolate shared conflict');
if (!ledger.changesApplied.some((change) => change.path === 'unique-b.txt' && change.action === 'add')) throw new Error('conflict ledger did not record unique add action');
if (!ledger.changesSkippedDueToConflict.some((change) => change.path === 'shared.txt' && change.action === 'modify')) throw new Error('conflict ledger did not record shared modify conflict action');
if (ledger.conflictMarkerPath !== markerPath) throw new Error('conflict marker path mismatch');
if (ledger.recoverableDiffPath !== diffPath) throw new Error('recoverable diff path mismatch');
if (!ledger.baseline?.fingerprint?.startsWith('sha256:')) throw new Error('missing baseline fingerprint');
if (!ledger.workspace?.fingerprint?.startsWith('sha256:')) throw new Error('missing workspace fingerprint');
if (!ledger.baseline?.manifest?.fingerprint?.startsWith('sha256:')) throw new Error('missing baseline manifest fingerprint');
if (!ledger.workspace?.manifest?.fingerprint?.startsWith('sha256:')) throw new Error('missing workspace manifest fingerprint');
NODE

trace_case "task-workspace-promotion-ledger-delete-conflict-isolated"
promotion_delete_conflict_state="$test_root_abs/promotion-delete-conflict-state"
promotion_delete_conflict_workspace="$test_root_abs/promotion-delete-conflict-workspace"
promotion_delete_conflict_base="$test_root_abs/promotion-delete-conflict-base"
promotion_delete_conflict_output_delete="$test_root_abs/promotion-delete-conflict-output-delete.txt"
promotion_delete_conflict_output_edit="$test_root_abs/promotion-delete-conflict-output-edit.txt"
mkdir -p "$promotion_delete_conflict_workspace"
printf '%s\n' 'delete conflict baseline' >"$promotion_delete_conflict_workspace/delete-conflict.txt"
run_task_workspace_harness "$promotion_delete_conflict_state" "$promotion_delete_conflict_workspace" "$promotion_delete_conflict_base" ensure ledger-delete-conflict-delete \
  >"$promotion_delete_conflict_output_delete" 2>&1
run_task_workspace_harness "$promotion_delete_conflict_state" "$promotion_delete_conflict_workspace" "$promotion_delete_conflict_base" ensure ledger-delete-conflict-edit \
  >"$promotion_delete_conflict_output_edit" 2>&1
grep -F 'ok' "$promotion_delete_conflict_output_delete" >/dev/null
grep -F 'ok' "$promotion_delete_conflict_output_edit" >/dev/null
rm -f "$promotion_delete_conflict_workspace/.clasp-task-workspaces/ledger-delete-conflict-delete/delete-conflict.txt"
printf '%s\n' 'delete branch unique' >"$promotion_delete_conflict_workspace/.clasp-task-workspaces/ledger-delete-conflict-delete/delete-branch-unique.txt"
printf '%s\n' 'edited by another branch' >"$promotion_delete_conflict_workspace/.clasp-task-workspaces/ledger-delete-conflict-edit/delete-conflict.txt"
run_task_workspace_harness "$promotion_delete_conflict_state" "$promotion_delete_conflict_workspace" "$promotion_delete_conflict_base" promote ledger-delete-conflict-edit \
  >"$promotion_delete_conflict_output_edit" 2>&1
run_task_workspace_harness "$promotion_delete_conflict_state" "$promotion_delete_conflict_workspace" "$promotion_delete_conflict_base" promote ledger-delete-conflict-delete \
  >"$promotion_delete_conflict_output_delete" 2>&1
grep -F 'ok' "$promotion_delete_conflict_output_edit" >/dev/null
grep -F 'error:task workspace promotion failed' "$promotion_delete_conflict_output_delete" >/dev/null
grep -Fx 'edited by another branch' "$promotion_delete_conflict_workspace/delete-conflict.txt" >/dev/null
grep -Fx 'delete branch unique' "$promotion_delete_conflict_workspace/delete-branch-unique.txt" >/dev/null
test -f "$promotion_delete_conflict_state/loop-ledger-delete-conflict-delete/promotion-conflict.marker"
test -f "$promotion_delete_conflict_state/loop-ledger-delete-conflict-delete/promotion-recoverable.diff"
node - "$promotion_delete_conflict_state/loop-ledger-delete-conflict-delete/promotion-ledger.json" <<'NODE'
const fs = require('fs');
const ledger = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (ledger.status !== 'conflict' || ledger.conflicted !== true) throw new Error('expected delete conflict ledger');
if (!ledger.filesApplied.includes('delete-branch-unique.txt')) throw new Error('delete conflict ledger did not preserve unique file');
if (!ledger.filesSkippedDueToConflict.includes('delete-conflict.txt')) throw new Error('delete conflict ledger missing delete conflict path');
if (!ledger.changesApplied.some((change) => change.path === 'delete-branch-unique.txt' && change.action === 'add')) throw new Error('delete conflict ledger missing unique add action');
if (!ledger.changesSkippedDueToConflict.some((change) => change.path === 'delete-conflict.txt' && change.action === 'delete')) throw new Error('delete conflict ledger missing delete conflict action');
if (!ledger.baseline?.fingerprint?.startsWith('sha256:')) throw new Error('delete conflict ledger missing baseline fingerprint');
if (!ledger.workspace?.fingerprint?.startsWith('sha256:')) throw new Error('delete conflict ledger missing workspace fingerprint');
if (!ledger.baseline?.manifest?.fingerprint?.startsWith('sha256:')) throw new Error('delete conflict ledger missing baseline manifest fingerprint');
if (!ledger.workspace?.manifest?.fingerprint?.startsWith('sha256:')) throw new Error('delete conflict ledger missing workspace manifest fingerprint');
NODE

trace_case "active-child-wait-does-not-spin"
active_wait_state="$test_root_abs/active-wait-state"
active_wait_workspace="$test_root_abs/active-wait-workspace"
active_wait_output="$test_root_abs/active-wait-output.txt"
mkdir -p "$active_wait_workspace"
run_goal_manager "$active_wait_state" "$active_wait_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_CHILD_SLEEP_SECS='1' \
  CLASP_MANAGER_TRACE_JSON='true' \
  CLASP_LOOP_WATCH_POLL_MS_JSON='10' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$active_wait_output" 2>&1 &
goal_manager_live_pid=$!
wait_for_path_contains "$active_wait_state/status.json" '"phase":"task-running"' "" 1200 0.05
wait_for_path_contains "$active_wait_state/loop-benchmark-gap/loop.process.heartbeat.json" '"running":true' "" 600 0.05
sleep 0.25
active_wait_launch_returns=0
if [[ -f "$active_wait_state/trace.log" ]]; then
  active_wait_launch_returns="$(grep -c 'launch-ready:return' "$active_wait_state/trace.log" 2>/dev/null || true)"
fi
stop_goal_manager_service "$active_wait_state"
wait_or_kill_pid "$goal_manager_live_pid" 100
goal_manager_live_pid=""
if (( active_wait_launch_returns > 3 )); then
  echo "active child wait spun in Clasp recursion; launch-ready:return count=$active_wait_launch_returns" >&2
  sed -n '1,120p' "$active_wait_state/trace.log" >&2 || true
  exit 1
fi

trace_case "child-verifier-export-crash-preserves-builder-progress"
preserve_verifier_state="$test_root_abs/preserve-verifier-state"
preserve_verifier_workspace="$test_root_abs/preserve-verifier-workspace"
preserve_verifier_output="$test_root_abs/preserve-verifier-output.txt"
mkdir -p "$preserve_verifier_workspace"
run_goal_manager "$preserve_verifier_state" "$preserve_verifier_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_CHILD_VERIFIER_EXPORT_CRASH_ONCE='1' \
  CLASP_TEST_FAKE_CHILD_REQUIRE_PRESERVED_VERIFIER_STATE='1' \
  CLASP_MANAGER_TRACE_JSON='true' \
  CLASP_MANAGER_CHILD_MAX_ATTEMPTS_JSON='2' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$preserve_verifier_output" 2>&1
grep -F '"phase":"completed"' "$preserve_verifier_output" >/dev/null
grep -F '"verdict":"pass"' "$preserve_verifier_output" >/dev/null
grep -F 'child-loop-retry:benchmark-gap:missing-durable-report:retry=1' "$preserve_verifier_state/trace.log" >/dev/null
grep -F 'child-loop-retry:benchmark-gap:preserve-builder-progress=true' "$preserve_verifier_state/trace.log" >/dev/null
grep -F '"summary":"fake child loop completed"' "$preserve_verifier_state/loop-benchmark-gap/feedback.json" >/dev/null
grep -Fx 'fixed-after-feedback' "$preserve_verifier_workspace/workspace.txt" >/dev/null
grep -Fx 'preserve-builder-progress' "$preserve_verifier_workspace/.clasp-task-workspaces/benchmark-gap/preserve-builder-progress.txt" >/dev/null

if [[ "${CLASP_GOAL_MANAGER_FAST_EXTENDED:-0}" == "1" ]]; then
trace_case "relative-workspace-ready-link"
relative_workspace_project="$test_root_abs/relative-workspace-project"
relative_workspace_state="$test_root_abs/relative-workspace-state"
relative_workspace_output="$test_root_abs/relative-workspace-output.txt"
mkdir -p "$relative_workspace_project"
mkdir -p \
  "$relative_workspace_project/benchmarks/workspaces/generated" \
  "$relative_workspace_project/benchmarks/results"
printf '%s\n' 'generated-benchmark-noise' >"$relative_workspace_project/benchmarks/workspaces/generated/noise.txt"
printf '%s\n' 'generated-benchmark-result' >"$relative_workspace_project/benchmarks/results/noise.txt"
(
  cd "$relative_workspace_project"
  run_goal_manager "$relative_workspace_state" "." \
    CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
    CLASP_MANAGER_MAX_WAVES_JSON='1' \
    >"$relative_workspace_output" 2>&1
)
grep -F '"phase":"completed"' "$relative_workspace_output" >/dev/null
grep -F '"verdict":"pass"' "$relative_workspace_output" >/dev/null
test -f "$relative_workspace_project/.clasp-task-workspaces/benchmark-gap/.workspace-ready"
relative_workspace_link_target="$(readlink "$relative_workspace_state/workspace-benchmark-gap")"
case "$relative_workspace_link_target" in
  /*) ;;
  *)
    echo "expected absolute task workspace symlink target, got: $relative_workspace_link_target" >&2
    exit 1
    ;;
esac
grep -Fx 'fixed-after-feedback' "$relative_workspace_project/workspace.txt" >/dev/null
test ! -e "$relative_workspace_project/.clasp-test-tmp/noise.txt"
test ! -e "$relative_workspace_project/.clasp-task-workspaces/benchmark-gap/benchmarks/workspaces/generated/noise.txt"
test ! -e "$relative_workspace_project/.clasp-task-baselines/benchmark-gap/benchmarks/results/noise.txt"

trace_case "workspace-cache-retention"
retention_workspace_project="$test_root_abs/retention-workspace-project"
retention_workspace_state="$test_root_abs/retention-workspace-state"
retention_workspace_output="$test_root_abs/retention-workspace-output.txt"
mkdir -p \
  "$retention_workspace_project/.clasp-task-workspaces/old-workspace" \
  "$retention_workspace_project/.clasp-task-baselines/old-baseline"
dd if=/dev/zero of="$retention_workspace_project/.clasp-task-workspaces/old-workspace/payload.bin" bs=1024 count=2048 status=none
dd if=/dev/zero of="$retention_workspace_project/.clasp-task-baselines/old-baseline/payload.bin" bs=1024 count=2048 status=none
touch -t 202001010000 "$retention_workspace_project/.clasp-task-workspaces/old-workspace" "$retention_workspace_project/.clasp-task-baselines/old-baseline"
(
  cd "$retention_workspace_project"
  run_goal_manager "$retention_workspace_state" "." \
    CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
    CLASP_MANAGER_MAX_WAVES_JSON='1' \
    CLASP_MANAGER_TASK_WORKSPACE_CACHE_MAX_MB_JSON='1' \
    CLASP_MANAGER_TASK_BASELINE_CACHE_MAX_MB_JSON='1' \
    >"$retention_workspace_output" 2>&1
)
grep -F '"phase":"completed"' "$retention_workspace_output" >/dev/null
grep -F '"verdict":"pass"' "$retention_workspace_output" >/dev/null
test ! -e "$retention_workspace_project/.clasp-task-workspaces/old-workspace"
test ! -e "$retention_workspace_project/.clasp-task-baselines/old-baseline"
test -f "$retention_workspace_project/.clasp-task-workspaces/benchmark-gap/.workspace-ready"

trace_case "child-loop-cache-retention"
child_cache_state="$test_root_abs/child-cache-state"
child_cache_workspace="$test_root_abs/child-cache-workspace"
child_cache_output="$test_root_abs/child-cache-output.txt"
mkdir -p   "$child_cache_state/loop-old-final/baseline-cache"   "$child_cache_state/loop-old-final/xdg-cache"   "$child_cache_state/loop-active/baseline-cache"   "$child_cache_state/loop-active/xdg-cache"   "$child_cache_workspace"
dd if=/dev/zero of="$child_cache_state/loop-old-final/baseline-cache/payload.bin" bs=1024 count=2048 status=none
dd if=/dev/zero of="$child_cache_state/loop-old-final/xdg-cache/payload.bin" bs=1024 count=2048 status=none
dd if=/dev/zero of="$child_cache_state/loop-active/baseline-cache/payload.bin" bs=1024 count=2048 status=none
dd if=/dev/zero of="$child_cache_state/loop-active/xdg-cache/payload.bin" bs=1024 count=2048 status=none
cat >"$child_cache_state/loop-old-final/state.json" <<'JSON'
{"attempt":1,"phase":"completed","verdict":"pass","completed":true,"builderRuns":1,"verifierRuns":1,"healthy":true,"needsAttention":false,"attentionReason":"","final":true}
JSON
cat >"$child_cache_state/loop-active/state.json" <<'JSON'
{"attempt":1,"phase":"builder-running","verdict":"pending","completed":false,"builderRuns":1,"verifierRuns":0,"healthy":true,"needsAttention":false,"attentionReason":"","final":false}
JSON
touch -t 202001010000 "$child_cache_state/loop-old-final/baseline-cache" "$child_cache_state/loop-old-final/xdg-cache"
run_goal_manager "$child_cache_state" "$child_cache_workspace"   CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan'   CLASP_MANAGER_MAX_WAVES_JSON='1'   CLASP_MANAGER_CHILD_LOOP_BASELINE_CACHE_TOTAL_MAX_MB_JSON='1'   CLASP_MANAGER_CHILD_LOOP_XDG_CACHE_TOTAL_MAX_MB_JSON='1'   >"$child_cache_output" 2>&1
grep -F '"phase":"completed"' "$child_cache_output" >/dev/null
grep -F '"verdict":"pass"' "$child_cache_output" >/dev/null
test ! -e "$child_cache_state/loop-old-final/baseline-cache"
test ! -e "$child_cache_state/loop-old-final/xdg-cache"
test -e "$child_cache_state/loop-active/baseline-cache"
test -e "$child_cache_state/loop-active/xdg-cache"

trace_case "child-crash-durable-report-and-cleanup"
crash_cleanup_state="$test_root_abs/crash-cleanup-state"
crash_cleanup_workspace="$test_root_abs/crash-cleanup-workspace"
crash_cleanup_output="$test_root_abs/crash-cleanup-output.txt"
mkdir -p "$crash_cleanup_workspace"
run_goal_manager "$crash_cleanup_state" "$crash_cleanup_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_CHILD_CRASH_NO_REPORT='1' \
  CLASP_MANAGER_CHILD_MAX_ATTEMPTS_JSON='1' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$crash_cleanup_output" 2>&1
grep -F '"phase":"failed"' "$crash_cleanup_output" >/dev/null
grep -F '"verdict":"fail"' "$crash_cleanup_output" >/dev/null
grep -F '"summary":"task child loop finished without a durable report"' "$crash_cleanup_state/loop-benchmark-gap/feedback.json" >/dev/null
grep -F 'exitCode=43' "$crash_cleanup_state/loop-benchmark-gap/feedback.json" >/dev/null
grep -F 'fake child crashed before durable report' "$crash_cleanup_state/loop-benchmark-gap/feedback.json" >/dev/null
test ! -e "$crash_cleanup_workspace/.clasp-task-workspaces/benchmark-gap"
test ! -e "$crash_cleanup_workspace/.clasp-task-baselines/benchmark-gap"

trace_case "child-verifier-export-crash-durable-report-gate"
verifier_crash_gate_state="$test_root_abs/verifier-crash-gate-state"
verifier_crash_gate_workspace="$test_root_abs/verifier-crash-gate-workspace"
verifier_crash_gate_output="$test_root_abs/verifier-crash-gate-output.txt"
mkdir -p "$verifier_crash_gate_workspace"
run_goal_manager "$verifier_crash_gate_state" "$verifier_crash_gate_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_CHILD_VERIFIER_EXPORT_CRASH_ONCE='1' \
  CLASP_MANAGER_CHILD_MAX_ATTEMPTS_JSON='1' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$verifier_crash_gate_output" 2>&1
grep -F '"phase":"failed"' "$verifier_crash_gate_output" >/dev/null
grep -F '"verdict":"fail"' "$verifier_crash_gate_output" >/dev/null
grep -F '"summary":"task child loop finished without a durable report"' "$verifier_crash_gate_state/loop-benchmark-gap/feedback.json" >/dev/null
grep -F 'builderReportPath=' "$verifier_crash_gate_state/loop-benchmark-gap/feedback.json" >/dev/null
grep -F 'builder-1.json' "$verifier_crash_gate_state/loop-benchmark-gap/feedback.json" >/dev/null
grep -F 'builderReportSummary=fake child builder report before verifier export crash for benchmark-gap' "$verifier_crash_gate_state/loop-benchmark-gap/feedback.json" >/dev/null
grep -F 'builderFeedbackSummary=builder completed before verifier export crash' "$verifier_crash_gate_state/loop-benchmark-gap/feedback.json" >/dev/null
grep -F 'state={' "$verifier_crash_gate_state/loop-benchmark-gap/feedback.json" >/dev/null
grep -F '"phase":"verifier-step-ready"' "$verifier_crash_gate_state/loop-benchmark-gap/feedback.json" >/dev/null
grep -F 'stderr_tail=runtime failed to execute native compiler export' "$verifier_crash_gate_state/loop-benchmark-gap/feedback.json" >/dev/null
grep -F 'stdout_tail=fake verifier stdout before export crash for benchmark-gap' "$verifier_crash_gate_state/loop-benchmark-gap/feedback.json" >/dev/null
grep -F 'recoverableDiff=' "$verifier_crash_gate_state/loop-benchmark-gap/feedback.json" >/dev/null
grep -F 'recoverableDiffKind=child-loop' "$verifier_crash_gate_state/loop-benchmark-gap/feedback.json" >/dev/null
grep -F 'builderReportSummary=fake child builder report before verifier export crash for benchmark-gap' "$verifier_crash_gate_state/mailbox.json" >/dev/null
grep -F 'builderFeedbackSummary=builder completed before verifier export crash' "$verifier_crash_gate_state/mailbox.json" >/dev/null
grep -F 'recoverableDiffKind=child-loop' "$verifier_crash_gate_state/mailbox.json" >/dev/null

trace_case "child-crash-once-retries-before-fail"
crash_retry_state="$test_root_abs/crash-retry-state"
crash_retry_workspace="$test_root_abs/crash-retry-workspace"
crash_retry_output="$test_root_abs/crash-retry-output.txt"
mkdir -p "$crash_retry_workspace"
run_goal_manager "$crash_retry_state" "$crash_retry_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_CHILD_CRASH_ONCE_NO_REPORT='1' \
  CLASP_MANAGER_TRACE_JSON='true' \
  CLASP_MANAGER_CHILD_MAX_ATTEMPTS_JSON='2' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$crash_retry_output" 2>&1
grep -F '"phase":"completed"' "$crash_retry_output" >/dev/null
grep -F '"verdict":"pass"' "$crash_retry_output" >/dev/null
grep -F 'child-loop-retry:benchmark-gap:missing-durable-report:retry=1' "$crash_retry_state/trace.log" >/dev/null
grep -Fx 'fixed-after-feedback' "$crash_retry_workspace/workspace.txt" >/dev/null
test -f "$crash_retry_workspace/.clasp-task-workspaces/benchmark-gap/.workspace-ready"

trace_case "child-verifier-export-crash-retries-before-fail"
verifier_crash_retry_state="$test_root_abs/verifier-crash-retry-state"
verifier_crash_retry_workspace="$test_root_abs/verifier-crash-retry-workspace"
verifier_crash_retry_output="$test_root_abs/verifier-crash-retry-output.txt"
mkdir -p "$verifier_crash_retry_workspace"
run_goal_manager "$verifier_crash_retry_state" "$verifier_crash_retry_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_CHILD_VERIFIER_EXPORT_CRASH_ONCE='1' \
  CLASP_TEST_FAKE_CHILD_REQUIRE_PRESERVED_VERIFIER_STATE='1' \
  CLASP_MANAGER_TRACE_JSON='true' \
  CLASP_MANAGER_CHILD_MAX_ATTEMPTS_JSON='2' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$verifier_crash_retry_output" 2>&1
grep -F '"phase":"completed"' "$verifier_crash_retry_output" >/dev/null
grep -F '"verdict":"pass"' "$verifier_crash_retry_output" >/dev/null
grep -F 'child-loop-retry:benchmark-gap:missing-durable-report:retry=1' "$verifier_crash_retry_state/trace.log" >/dev/null
grep -F 'child-loop-retry:benchmark-gap:preserve-builder-progress=true' "$verifier_crash_retry_state/trace.log" >/dev/null
grep -F '"summary":"fake child loop completed"' "$verifier_crash_retry_state/loop-benchmark-gap/feedback.json" >/dev/null
grep -Fx 'fixed-after-feedback' "$verifier_crash_retry_workspace/workspace.txt" >/dev/null
grep -Fx 'preserve-builder-progress' "$verifier_crash_retry_workspace/.clasp-task-workspaces/benchmark-gap/preserve-builder-progress.txt" >/dev/null

trace_case "child-report-settles-after-process-exit"
settle_report_state="$test_root_abs/settle-report-state"
settle_report_workspace="$test_root_abs/settle-report-workspace"
settle_report_output="$test_root_abs/settle-report-output.txt"
mkdir -p "$settle_report_workspace"
run_goal_manager "$settle_report_state" "$settle_report_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_CHILD_DELAY_REPORT_AFTER_EXIT='1' \
  CLASP_TEST_FAKE_CHILD_DELAY_REPORT_SECS='0.2' \
  CLASP_MANAGER_CHILD_REPORT_SETTLE_POLLS_JSON='12' \
  CLASP_LOOP_WATCH_POLL_MS_JSON='50' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$settle_report_output" 2>&1
grep -F '"phase":"completed"' "$settle_report_output" >/dev/null
grep -F '"verdict":"pass"' "$settle_report_output" >/dev/null
grep -F '"summary":"fake child loop completed after report settle"' "$settle_report_state/loop-benchmark-gap/feedback.json" >/dev/null
if grep -F 'missing-durable-report' "$settle_report_state/trace.log" >/dev/null 2>&1; then
  echo "settled child report should not consume a missing-report retry" >&2
  exit 1
fi

trace_case "stale-child-inner-heartbeat-completes"
stale_child_state="$test_root_abs/stale-child-state"
stale_child_workspace="$test_root_abs/stale-child-workspace"
stale_child_output="$test_root_abs/stale-child-output.txt"
stale_child_loop="$stale_child_state/loop-stale-child"
mkdir -p "$stale_child_workspace" "$stale_child_loop"
"$claspc_bin" --json swarm objective create "$stale_child_state" improve-clasp --max-tasks 64 --max-runs 64 >/dev/null
"$claspc_bin" --json swarm task create "$stale_child_state" improve-clasp stale-child --max-runs 1 --lease-timeout-ms 3600000 >/dev/null
"$claspc_bin" --json swarm lease "$stale_child_state" stale-child >/dev/null
cat >"$stale_child_state/status.json" <<'JSON'
{"phase":"task-running","verdict":"pending","completed":false,"objectiveId":"improve-clasp","plannerTaskId":"planner","activeTaskId":"stale-child","plannedTaskIds":["stale-child"],"wave":1,"benchmarkRuns":0,"final":false}
JSON
cat >"$stale_child_state/planner-1.json" <<'JSON'
{"objectiveSummary":"Recover stale child launch heartbeat.","strategy":"The inner child heartbeat is authoritative when the outer launch heartbeat is stale.","tasks":[{"taskId":"stale-child","role":"stale-heartbeat-regression","detail":"Recover a child whose builder heartbeat has completed but whose launch heartbeat still claims to run.","dependencies":[],"taskPrompt":"This task should be reconciled as failed without waiting forever.","coordinationFocus":["stale-heartbeat-recovery"]}],"testsRun":["stale-child-inner-heartbeat-completes"],"residualRisks":[]}
JSON
cat >"$stale_child_loop/state.json" <<'JSON'
{"attempt":1,"phase":"builder-running","verdict":"pending","completed":false,"builderRuns":1,"verifierRuns":0,"healthy":true,"needsAttention":false,"attentionReason":"","final":false}
JSON
cat >"$stale_child_loop/loop.process.heartbeat.json" <<JSON
{"completed":false,"exitCode":-1,"heartbeatPath":"$stale_child_loop/loop.process.heartbeat.json","pid":$$,"running":true,"stderrPath":"$stale_child_loop/loop.stderr.log","stdoutPath":"$stale_child_loop/loop.stdout.log","updatedAtMs":0}
JSON
cat >"$stale_child_loop/builder-1.heartbeat.json" <<JSON
{"completed":true,"exitCode":-1,"heartbeatPath":"$stale_child_loop/builder-1.heartbeat.json","pid":0,"running":false,"stderrPath":"$stale_child_loop/builder-1.stderr.log","stdoutPath":"$stale_child_loop/builder-1.stdout.jsonl","updatedAtMs":0}
JSON
touch "$stale_child_loop/loop.stderr.log" "$stale_child_loop/loop.stdout.log" "$stale_child_loop/builder-1.stderr.log" "$stale_child_loop/builder-1.stdout.jsonl"
run_goal_manager "$stale_child_state" "$stale_child_workspace" \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$stale_child_output" 2>&1
grep -F '"phase":"completed"' "$stale_child_output" >/dev/null
grep -F '"verdict":"pass"' "$stale_child_output" >/dev/null
grep -Fx '1' "$stale_child_state/child-loop-retries-stale-child.json" >/dev/null
grep -F '"summary":"fake child loop completed"' "$stale_child_loop/feedback.json" >/dev/null

trace_case "leased-task-missing-launch-heartbeat-retries"
missing_launch_state="$test_root_abs/missing-launch-state"
missing_launch_workspace="$test_root_abs/missing-launch-workspace"
missing_launch_output="$test_root_abs/missing-launch-output.txt"
missing_launch_loop="$missing_launch_state/loop-heartbeat-gap"
mkdir -p "$missing_launch_workspace"
"$claspc_bin" --json swarm objective create "$missing_launch_state" improve-clasp --max-tasks 64 --max-runs 64 >/dev/null
"$claspc_bin" --json swarm task create "$missing_launch_state" improve-clasp heartbeat-gap --max-runs 1 --lease-timeout-ms 3600000 >/dev/null
"$claspc_bin" --json swarm lease "$missing_launch_state" heartbeat-gap >/dev/null
cat >"$missing_launch_state/status.json" <<'JSON'
{"phase":"task-running","verdict":"pending","completed":false,"objectiveId":"improve-clasp","plannerTaskId":"planner","activeTaskId":"heartbeat-gap","plannedTaskIds":["heartbeat-gap"],"wave":1,"benchmarkRuns":0,"final":false}
JSON
cat >"$missing_launch_state/planner-1.json" <<'JSON'
{"objectiveSummary":"Recover a leased task without a launch heartbeat.","strategy":"Requeue and relaunch leased tasks that never established a durable launch heartbeat.","tasks":[{"taskId":"heartbeat-gap","role":"launch-heartbeat-recovery","detail":"Recover a task that was leased but never wrote loop.process.heartbeat.json.","dependencies":[],"taskPrompt":"This task should be relaunched when the manager sees a lease with no launch heartbeat.","coordinationFocus":["launch-heartbeat-recovery"]}],"testsRun":["leased-task-missing-launch-heartbeat-retries"],"residualRisks":[]}
JSON
run_goal_manager "$missing_launch_state" "$missing_launch_workspace"   CLASP_MANAGER_TRACE_JSON='true'   CLASP_MANAGER_CHILD_MAX_ATTEMPTS_JSON='2'   CLASP_MANAGER_MAX_WAVES_JSON='1'   >"$missing_launch_output" 2>&1
grep -F '"phase":"completed"' "$missing_launch_output" >/dev/null
grep -F '"verdict":"pass"' "$missing_launch_output" >/dev/null
grep -F 'launch-outcome=missing-heartbeat' "$missing_launch_state/trace.log" >/dev/null
grep -F 'child-loop-retry:heartbeat-gap:missing-launch-heartbeat:retry=1' "$missing_launch_state/trace.log" >/dev/null
grep -Fx '1' "$missing_launch_state/child-loop-retries-heartbeat-gap.json" >/dev/null
grep -F '"summary":"fake child loop completed"' "$missing_launch_loop/feedback.json" >/dev/null

trace_case "invalid-launch-heartbeat-retries"
invalid_launch_state="$test_root_abs/invalid-launch-state"
invalid_launch_workspace="$test_root_abs/invalid-launch-workspace"
invalid_launch_output="$test_root_abs/invalid-launch-output.txt"
invalid_launch_loop="$invalid_launch_state/loop-invalid-heartbeat"
mkdir -p "$invalid_launch_workspace" "$invalid_launch_loop"
"$claspc_bin" --json swarm objective create "$invalid_launch_state" improve-clasp --max-tasks 64 --max-runs 64 >/dev/null
"$claspc_bin" --json swarm task create "$invalid_launch_state" improve-clasp invalid-heartbeat --max-runs 1 --lease-timeout-ms 3600000 >/dev/null
"$claspc_bin" --json swarm lease "$invalid_launch_state" invalid-heartbeat >/dev/null
cat >"$invalid_launch_state/status.json" <<'JSON'
{"phase":"task-running","verdict":"pending","completed":false,"objectiveId":"improve-clasp","plannerTaskId":"planner","activeTaskId":"invalid-heartbeat","plannedTaskIds":["invalid-heartbeat"],"wave":1,"benchmarkRuns":0,"final":false}
JSON
cat >"$invalid_launch_state/planner-1.json" <<'JSON'
{"objectiveSummary":"Recover a task with a malformed launch heartbeat.","strategy":"Treat an unresolved launch heartbeat as missing/stale and relaunch the child loop instead of waiting forever.","tasks":[{"taskId":"invalid-heartbeat","role":"launch-heartbeat-recovery","detail":"Recover a task whose loop.process heartbeat exists but does not resolve to running or completed.","dependencies":[],"taskPrompt":"This task should be relaunched when the manager sees an unresolved launch heartbeat file.","coordinationFocus":["launch-heartbeat-recovery"]}],"testsRun":["invalid-launch-heartbeat-retries"],"residualRisks":[]}
JSON
cat >"$invalid_launch_loop/loop.process.heartbeat.json" <<'JSON'
{}
JSON
run_goal_manager "$invalid_launch_state" "$invalid_launch_workspace"   CLASP_MANAGER_TRACE_JSON='true'   CLASP_MANAGER_CHILD_MAX_ATTEMPTS_JSON='2'   CLASP_MANAGER_MAX_WAVES_JSON='1'   >"$invalid_launch_output" 2>&1
grep -F '"phase":"completed"' "$invalid_launch_output" >/dev/null
grep -F '"verdict":"pass"' "$invalid_launch_output" >/dev/null
grep -F 'launch-outcome=malformed-unresolved-heartbeat' "$invalid_launch_state/trace.log" >/dev/null
grep -F 'child-loop-retry:invalid-heartbeat:missing-launch-heartbeat:retry=1' "$invalid_launch_state/trace.log" >/dev/null
grep -Fx '1' "$invalid_launch_state/child-loop-retries-invalid-heartbeat.json" >/dev/null
grep -F '"summary":"fake child loop completed"' "$invalid_launch_state/loop-invalid-heartbeat/feedback.json" >/dev/null

trace_case "default-claspc-resolution"
default_claspc_state="$test_root_abs/default-claspc-state"
default_claspc_workspace="$test_root_abs/default-claspc-workspace"
default_claspc_output="$test_root_abs/default-claspc-output.txt"
default_claspc_project="$test_root_abs/default-claspc-project"
default_claspc_repo_bin="$default_claspc_project/runtime/target/debug/claspc"
mkdir -p "$default_claspc_workspace" "$(dirname "$default_claspc_repo_bin")"
ln -s "$fake_child_claspc_bin" "$default_claspc_repo_bin"
run_goal_manager "$default_claspc_state" "$default_claspc_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_EXPECT_CHILD_XDG_CACHE='1' \
  CLASP_MANAGER_PROJECT_ROOT_JSON="\"$default_claspc_project\"" \
  CLASP_MANAGER_CLASPC_BIN_JSON='"claspc"' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$default_claspc_output" 2>&1
grep -F '"phase":"completed"' "$default_claspc_output" >/dev/null
grep -F '"verdict":"pass"' "$default_claspc_output" >/dev/null
grep -F 'fake child loop completed' "$default_claspc_state/loop-benchmark-gap/feedback.json" >/dev/null
grep -F "CLASP_MANAGER_CLASPC_BIN_JSON=\\\"$default_claspc_repo_bin\\\"" "$default_claspc_state/service/supervisor.config.json" >/dev/null
grep -F "XDG_CACHE_HOME=$default_claspc_state/manager-xdg-cache" "$default_claspc_state/service/supervisor.config.json" >/dev/null
if grep -F "No such file or directory" "$default_claspc_state/loop-benchmark-gap/loop.stderr.log" >/dev/null 2>&1; then
  echo "default claspc resolution unexpectedly used PATH lookup" >&2
  exit 1
fi
fi

trace_case "transient-planner-failure-retries-same-wave"
transient_planner_state="$test_root_abs/transient-planner-state"
transient_planner_workspace="$test_root_abs/transient-planner-workspace"
transient_planner_output="$test_root_abs/transient-planner-output.txt"
mkdir -p "$transient_planner_workspace"
run_goal_manager "$transient_planner_state" "$transient_planner_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_PLANNER_TRANSIENT_FAILS='1' \
  CLASP_MANAGER_TRACE_JSON='true' \
  CLASP_MANAGER_PLANNER_MAX_RUNS_JSON='2' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$transient_planner_output" 2>&1
grep -F '"phase":"completed"' "$transient_planner_output" >/dev/null
grep -F '"verdict":"pass"' "$transient_planner_output" >/dev/null
grep -F '"wave":1' "$transient_planner_state/status.json" >/dev/null
grep -F 'recoverable-transport-blocker' "$transient_planner_state/trace.log" >/dev/null

if [[ "$goal_manager_binary_fresh" == "1" ]]; then
trace_case "expired-planner-lease-resumes-same-wave"
expired_planner_state="$test_root_abs/expired-planner-state"
expired_planner_workspace="$test_root_abs/expired-planner-workspace"
expired_planner_output="$test_root_abs/expired-planner-output.txt"
mkdir -p "$expired_planner_workspace"
"$claspc_bin" --json swarm objective create "$expired_planner_state" improve-clasp --max-tasks 64 --max-runs 64 >/dev/null
"$claspc_bin" --json swarm task create "$expired_planner_state" improve-clasp planner --max-runs 2 --lease-timeout-ms 1 >/dev/null
"$claspc_bin" --json swarm lease "$expired_planner_state" planner >/dev/null
cat >"$expired_planner_state/status.json" <<'JSON'
{"phase":"planner-running","verdict":"pending","completed":false,"objectiveId":"improve-clasp","plannerTaskId":"planner","activeTaskId":"planner","plannedTaskIds":[],"wave":1,"benchmarkRuns":0,"final":false}
JSON
sleep 0.05
run_goal_manager "$expired_planner_state" "$expired_planner_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_MANAGER_TRACE_JSON='true' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$expired_planner_output" 2>&1
grep -F '"phase":"completed"' "$expired_planner_output" >/dev/null
grep -F '"verdict":"pass"' "$expired_planner_output" >/dev/null
grep -F 'resume-recover-expired-planner-lease' "$expired_planner_state/trace.log" >/dev/null

trace_case "expired-child-completion-lease-recovers"
expired_child_state="$test_root_abs/expired-child-state"
expired_child_workspace="$test_root_abs/expired-child-workspace"
expired_child_output="$test_root_abs/expired-child-output.txt"
mkdir -p "$expired_child_workspace"
run_goal_manager "$expired_child_state" "$expired_child_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_CHILD_SLEEP_SECS='2.2' \
  CLASP_MANAGER_TASK_LEASE_TIMEOUT_JSON='2000' \
  CLASP_MANAGER_TASK_PROMOTION_HEARTBEAT_JSON='false' \
  CLASP_MANAGER_TRACE_JSON='true' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$expired_child_output" 2>&1
grep -F '"phase":"completed"' "$expired_child_output" >/dev/null
grep -F '"verdict":"pass"' "$expired_child_output" >/dev/null
if grep -F '"summary":"planned task reconciliation failed"' "$expired_child_state/feedback.json" >/dev/null 2>&1; then
  echo "expired child completion leases should recover instead of final-failing reconciliation" >&2
  exit 1
fi

trace_case "manager-heartbeats-long-child-lease"
heartbeat_child_state="$test_root_abs/heartbeat-child-state"
heartbeat_child_workspace="$test_root_abs/heartbeat-child-workspace"
heartbeat_child_output="$test_root_abs/heartbeat-child-output.txt"
heartbeat_child_status="$test_root_abs/heartbeat-child-task.json"
mkdir -p "$heartbeat_child_workspace"
run_goal_manager "$heartbeat_child_state" "$heartbeat_child_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_CHILD_SLEEP_SECS='0.35' \
  CLASP_MANAGER_TASK_LEASE_TIMEOUT_JSON='5000' \
  CLASP_MANAGER_CHILD_AWAIT_TIMEOUT_MS_JSON='50' \
  CLASP_MANAGER_TRACE_JSON='true' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$heartbeat_child_output" 2>&1
grep -F '"phase":"completed"' "$heartbeat_child_output" >/dev/null
grep -F '"verdict":"pass"' "$heartbeat_child_output" >/dev/null
"$claspc_bin" --json swarm status "$heartbeat_child_state" benchmark-gap >"$heartbeat_child_status"
grep -F '"status":"completed"' "$heartbeat_child_status" >/dev/null
grep -F '"heartbeatSeen":true' "$heartbeat_child_status" >/dev/null
grep -F 'child-loop-await:benchmark-gap:status=timeout' "$heartbeat_child_state/trace.log" >/dev/null
if grep -F 'task-complete-expired-lease-recovered:benchmark-gap' "$heartbeat_child_state/trace.log" >/dev/null 2>&1; then
  echo "manager heartbeats should keep long child leases fresh instead of relying on completion recovery" >&2
  exit 1
fi

trace_case "bounded-child-await-reconciles-without-finalizing"
bounded_await_state="$test_root_abs/bounded-await-state"
bounded_await_workspace="$test_root_abs/bounded-await-workspace"
bounded_await_output="$test_root_abs/bounded-await-output.txt"
mkdir -p "$bounded_await_workspace"
run_goal_manager "$bounded_await_state" "$bounded_await_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_CHILD_SLEEP_SECS='0.45' \
  CLASP_MANAGER_CHILD_AWAIT_TIMEOUT_MS_JSON='120' \
  CLASP_MANAGER_TRACE_JSON='true' \
  CLASP_LOOP_WATCH_POLL_MS_JSON='10' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$bounded_await_output" 2>&1 &
goal_manager_live_pid=$!
wait_for_path_contains "$bounded_await_state/status.json" '"phase":"task-running"' "" 1200 0.05
wait_for_path_contains "$bounded_await_state/trace.log" 'launch-ready:return:error=:active=1' "" 1200 0.05
sleep 0.2
grep -F '"phase":"task-running"' "$bounded_await_state/status.json" >/dev/null
bounded_await_launch_returns="$(grep -c 'launch-ready:return' "$bounded_await_state/trace.log" 2>/dev/null || true)"
if (( bounded_await_launch_returns > 8 )); then
  echo "bounded child await spun too aggressively; launch-ready:return count=$bounded_await_launch_returns" >&2
  sed -n '1,160p' "$bounded_await_state/trace.log" >&2 || true
  exit 1
fi
wait_or_kill_pid "$goal_manager_live_pid" 200
goal_manager_live_pid=""
grep -F '"phase":"completed"' "$bounded_await_output" >/dev/null
grep -F '"verdict":"pass"' "$bounded_await_output" >/dev/null
grep -F '"summary":"fake child loop completed"' "$bounded_await_state/loop-benchmark-gap/feedback.json" >/dev/null

trace_case "malformed-planner-report-finalizes-without-export-crash"
malformed_planner_state="$test_root_abs/malformed-planner-state"
malformed_planner_workspace="$test_root_abs/malformed-planner-workspace"
malformed_planner_output="$test_root_abs/malformed-planner-output.txt"
mkdir -p "$malformed_planner_workspace"
run_goal_manager "$malformed_planner_state" "$malformed_planner_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_PLANNER_MALFORMED_REPORT='1' \
  CLASP_MANAGER_TRACE_JSON='true' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$malformed_planner_output" 2>&1
grep -F '"phase":"failed"' "$malformed_planner_output" >/dev/null
grep -F '"verdict":"fail"' "$malformed_planner_output" >/dev/null
grep -F '"final":true' "$malformed_planner_state/status.json" >/dev/null
grep -F '"summary":"planner report decode failed"' "$malformed_planner_state/feedback.json" >/dev/null
grep -F 'planner report missing required fields' "$malformed_planner_state/feedback.json" >/dev/null
if grep -F 'runtime failed to execute native compiler export' "$malformed_planner_output" >/dev/null 2>&1; then
  echo "malformed planner report should not crash the native export boundary" >&2
  exit 1
fi

trace_case "planner-validation-retries-same-wave"
planner_validation_state="$test_root_abs/planner-validation-state"
planner_validation_workspace="$test_root_abs/planner-validation-workspace"
planner_validation_output="$test_root_abs/planner-validation-output.txt"
mkdir -p "$planner_validation_workspace"
run_goal_manager "$planner_validation_state" "$planner_validation_workspace"   CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan'   CLASP_TEST_EXPECT_PLANNER_TASK_LIMIT='1'   CLASP_TEST_FAKE_PLANNER_OVERBUDGET_FAILS='1'   CLASP_MANAGER_TRACE_JSON='true'   CLASP_MANAGER_PLANNER_MAX_RUNS_JSON='2'   CLASP_MANAGER_MAX_WAVES_JSON='1'   >"$planner_validation_output" 2>&1
grep -F '"phase":"completed"' "$planner_validation_output" >/dev/null
grep -F '"verdict":"pass"' "$planner_validation_output" >/dev/null
grep -F '"wave":1' "$planner_validation_state/status.json" >/dev/null
grep -F 'recoverable-validation-blocker' "$planner_validation_state/trace.log" >/dev/null

trace_case "planner-timeout-retries-same-wave"
planner_timeout_state="$test_root_abs/planner-timeout-state"
planner_timeout_workspace="$test_root_abs/planner-timeout-workspace"
planner_timeout_output="$test_root_abs/planner-timeout-output.txt"
mkdir -p "$planner_timeout_workspace"
run_goal_manager "$planner_timeout_state" "$planner_timeout_workspace"   CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan'   CLASP_TEST_FAKE_PLANNER_TIMEOUT_FAILS='1'   CLASP_TEST_FAKE_PLANNER_TIMEOUT_SLEEP_SECS='2'   CLASP_MANAGER_TRACE_JSON='true'   CLASP_MANAGER_PLANNER_MAX_RUNS_JSON='2'   CLASP_MANAGER_PLANNER_TIMEOUT_MS_JSON='1000'   CLASP_MANAGER_MAX_WAVES_JSON='1'   >"$planner_timeout_output" 2>&1
grep -F '"phase":"completed"' "$planner_timeout_output" >/dev/null
grep -F '"verdict":"pass"' "$planner_timeout_output" >/dev/null
grep -F '"wave":1' "$planner_timeout_state/status.json" >/dev/null
grep -F 'planner-wave-1:run-command:start' "$planner_timeout_state/trace.log" >/dev/null
grep -F 'recoverable-transport-blocker' "$planner_timeout_state/trace.log" >/dev/null
grep -F 'exitCode=124' "$planner_timeout_state/trace.log" >/dev/null
grep -F 'planner command timed out after 1000ms' "$planner_timeout_state/trace.log" >/dev/null

trace_case "planner-usage-limit-stops-as-resource-blocker"
planner_usage_limit_state="$test_root_abs/planner-usage-limit-state"
planner_usage_limit_workspace="$test_root_abs/planner-usage-limit-workspace"
planner_usage_limit_output="$test_root_abs/planner-usage-limit-output.txt"
mkdir -p "$planner_usage_limit_workspace"
run_goal_manager "$planner_usage_limit_state" "$planner_usage_limit_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_TEST_FAKE_PLANNER_USAGE_LIMIT_FAILS='1' \
  CLASP_MANAGER_TRACE_JSON='true' \
  CLASP_MANAGER_PLANNER_MAX_RUNS_JSON='2' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$planner_usage_limit_output" 2>&1
grep -F '"phase":"failed"' "$planner_usage_limit_output" >/dev/null
grep -F '"verdict":"fail"' "$planner_usage_limit_output" >/dev/null
grep -F '"final":true' "$planner_usage_limit_state/status.json" >/dev/null
grep -F '"summary":"planner external resource blocked"' "$planner_usage_limit_state/feedback.json" >/dev/null
grep -F "You've hit your usage limit" "$planner_usage_limit_state/feedback.json" >/dev/null
grep -F 'external-resource-blocker' "$planner_usage_limit_state/trace.log" >/dev/null
if grep -F 'recoverable-transport-blocker' "$planner_usage_limit_state/trace.log" >/dev/null 2>&1; then
  echo "planner usage limits should not be treated as recoverable transport failures" >&2
  exit 1
fi
if [[ "$(cat "$planner_usage_limit_state/.fake-planner-usage-limit-planner-1.json")" != "1" ]]; then
  echo "planner usage limit blocker should stop after one planner attempt" >&2
  exit 1
fi
else
trace_case "stale-goal-manager-binary-skips-fresh-planner-recovery-regressions"
fi

trace_case "preflight-budget-contract-fails-before-planner"
preflight_budget_state="$test_root_abs/preflight-budget-state"
preflight_budget_workspace="$test_root_abs/preflight-budget-workspace"
preflight_budget_output="$test_root_abs/preflight-budget-output.txt"
mkdir -p "$preflight_budget_workspace"
run_goal_manager "$preflight_budget_state" "$preflight_budget_workspace" \
  CLASP_TEST_FAIL_IF_PLANNER_RUN='1' \
  CLASP_MANAGER_MAX_TASKS_JSON='2' \
  CLASP_MANAGER_MAX_WAVES_JSON='2' \
  CLASP_MANAGER_OBJECTIVE_MAX_TASKS_JSON='5' \
  CLASP_MANAGER_OBJECTIVE_MAX_RUNS_JSON='5' \
  CLASP_MANAGER_BENCHMARK_COMMAND_JSON="[\"$fake_replan_benchmark_bin\"]" \
  >"$preflight_budget_output" 2>&1
grep -F '"phase":"failed"' "$preflight_budget_output" >/dev/null
grep -F '"verdict":"fail"' "$preflight_budget_output" >/dev/null
grep -F 'config-error:objective-task-budget-too-small:configured=5:required=6' "$preflight_budget_state/feedback.json" >/dev/null
grep -F '"summary":"manager setup failed"' "$preflight_budget_state/feedback.json" >/dev/null
if [[ -e "$preflight_budget_state/planner-1.json" ]]; then
  echo "preflight budget failure should stop before planner output exists" >&2
  exit 1
fi

trace_case "preflight-retry-contract-fails-before-planner"
preflight_retry_state="$test_root_abs/preflight-retry-state"
preflight_retry_workspace="$test_root_abs/preflight-retry-workspace"
preflight_retry_output="$test_root_abs/preflight-retry-output.txt"
mkdir -p "$preflight_retry_workspace"
run_goal_manager "$preflight_retry_state" "$preflight_retry_workspace" \
  CLASP_TEST_FAIL_IF_PLANNER_RUN='1' \
  CLASP_MANAGER_CHILD_MAX_ATTEMPTS_JSON='0' \
  >"$preflight_retry_output" 2>&1
grep -F '"phase":"failed"' "$preflight_retry_output" >/dev/null
grep -F '"verdict":"fail"' "$preflight_retry_output" >/dev/null
grep -F 'config-error:child-max-attempts-must-be-positive' "$preflight_retry_state/feedback.json" >/dev/null
if [[ -e "$preflight_retry_state/planner-1.json" ]]; then
  echo "preflight retry failure should stop before planner output exists" >&2
  exit 1
fi

if [[ "${CLASP_GOAL_MANAGER_FAST_EXTENDED:-0}" == "1" ]]; then
trace_case "stale-final-planner-transport-resume"
stale_transport_state="$test_root_abs/stale-transport-state"
stale_transport_workspace="$test_root_abs/stale-transport-workspace"
stale_transport_output="$test_root_abs/stale-transport-output.txt"
stale_transport_stderr="$stale_transport_state/planner.synthetic.stderr.txt"
stale_transport_stdout="$stale_transport_state/planner.synthetic.stdout.txt"
mkdir -p "$stale_transport_workspace"
"$claspc_bin" --json swarm objective create "$stale_transport_state" improve-clasp --max-tasks 64 --max-runs 64 >/dev/null
"$claspc_bin" --json swarm task create "$stale_transport_state" improve-clasp planner --max-runs 2 --lease-timeout-ms 3600000 >/dev/null
printf '%s\n' 'Reading additional input from stdin...' >"$stale_transport_stderr"
printf '%s\n' "We're currently experiencing high demand, which may cause temporary errors." >"$stale_transport_stdout"
printf '%s\n' 'stream disconnected before completion: websocket closed by server before response.completed' >>"$stale_transport_stdout"
printf '%s\n' 'turn.failed' >>"$stale_transport_stdout"
cat >"$stale_transport_state/status.json" <<'JSON'
{"phase":"failed","verdict":"fail","completed":false,"objectiveId":"improve-clasp","plannerTaskId":"planner","activeTaskId":"planner","plannedTaskIds":[],"wave":1,"benchmarkRuns":0,"final":true}
JSON
cat >"$stale_transport_state/feedback.json" <<JSON
{"verdict":"fail","summary":"planner step failed before producing a durable report","findings":["$stale_transport_stderr"],"tests_run":[],"follow_up":[],"capability_statuses":[]}
JSON
run_goal_manager "$stale_transport_state" "$stale_transport_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_MANAGER_TRACE_JSON='true' \
  CLASP_MANAGER_PLANNER_MAX_RUNS_JSON='2' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$stale_transport_output" 2>&1
grep -F '"phase":"completed"' "$stale_transport_output" >/dev/null
grep -F '"verdict":"pass"' "$stale_transport_output" >/dev/null
grep -F '"wave":1' "$stale_transport_state/status.json" >/dev/null
if grep -F 'planner step failed before producing a durable report' "$stale_transport_state/feedback.json" >/dev/null 2>&1; then
  echo "stale planner transport failure should resume instead of staying terminal" >&2
  exit 1
fi

trace_case "stale-planner-lease-replans-next-wave"
stale_planner_state="$test_root_abs/stale-planner-state"
stale_planner_workspace="$test_root_abs/stale-planner-workspace"
stale_planner_output="$test_root_abs/stale-planner-output.txt"
mkdir -p "$stale_planner_workspace"
"$claspc_bin" --json swarm objective create "$stale_planner_state" improve-clasp --max-tasks 64 --max-runs 64 >/dev/null
"$claspc_bin" --json swarm task create "$stale_planner_state" improve-clasp planner --max-runs 1 --lease-timeout-ms 3600000 >/dev/null
"$claspc_bin" --json swarm lease "$stale_planner_state" planner >/dev/null
"$claspc_bin" --json swarm tool "$stale_planner_state" planner -- bash -lc true >/dev/null
cat >"$stale_planner_state/status.json" <<'JSON'
{"phase":"failed","verdict":"fail","completed":false,"objectiveId":"improve-clasp","plannerTaskId":"planner","activeTaskId":"planner","plannedTaskIds":[],"wave":1,"benchmarkRuns":0,"final":true}
JSON
cat >"$stale_planner_state/feedback.json" <<'JSON'
{"verdict":"fail","summary":"planner lease failed","findings":["swarm task `planner` is not ready: lease held by `manager`; task run budget exhausted"],"tests_run":[],"follow_up":[],"capability_statuses":[]}
JSON
run_goal_manager "$stale_planner_state" "$stale_planner_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_MANAGER_MAX_WAVES_JSON='2' \
  >"$stale_planner_output" 2>&1
grep -F '"phase":"completed"' "$stale_planner_output" >/dev/null
grep -F '"verdict":"pass"' "$stale_planner_output" >/dev/null
grep -F '"plannerTaskId":"planner-2"' "$stale_planner_state/status.json" >/dev/null
if grep -F 'planner lease failed' "$stale_planner_state/feedback.json" >/dev/null 2>&1; then
  echo "stale planner lease should replan instead of final-failing" >&2
  exit 1
fi
fi

trace_case "promotion-conflict"
promotion_conflict_state="$test_root_abs/promotion-conflict-state"
promotion_conflict_workspace="$test_root_abs/promotion-conflict-workspace"
promotion_conflict_output="$test_root_abs/promotion-conflict-output.txt"
mkdir -p "$promotion_conflict_workspace"
run_goal_manager "$promotion_conflict_state" "$promotion_conflict_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='parallel-ready' \
  CLASP_TEST_FAKE_PROMOTION_CONFLICT='1' \
  CLASP_MANAGER_MAX_TASKS_JSON='2' \
  CLASP_MANAGER_MAX_CONCURRENT_CHILDREN_JSON='2' \
  >"$promotion_conflict_output" 2>&1
grep -F '"phase":"failed"' "$promotion_conflict_output" >/dev/null
grep -F '"verdict":"fail"' "$promotion_conflict_output" >/dev/null
grep -F '"summary":"one or more planned tasks failed"' "$promotion_conflict_state/feedback.json" >/dev/null
grep -R -F '"summary":"task promotion failed"' "$promotion_conflict_state"/loop-*/feedback.json >/dev/null
grep -R -F 'promotion conflict: task workspace would overwrite files changed since snapshot' "$promotion_conflict_state"/loop-*/feedback.json >/dev/null
grep -R -F 'promotionLedger=' "$promotion_conflict_state"/loop-*/feedback.json >/dev/null
grep -R -F 'recoverableDiffKind=promotion-workspace' "$promotion_conflict_state"/loop-*/feedback.json >/dev/null
promotion_ledger="$(
  grep -Roh 'promotionLedger=[^"]*' "$promotion_conflict_state"/loop-*/feedback.json | head -1 | cut -d= -f2-
)"
promotion_recoverable_diff="$(
  grep -Roh 'recoverableDiff=[^"]*' "$promotion_conflict_state"/loop-*/feedback.json | head -1 | cut -d= -f2-
)"
test -f "$promotion_ledger"
test -f "$promotion_recoverable_diff"
grep -F 'fixed-after-feedback' "$promotion_recoverable_diff" >/dev/null
node - "$promotion_ledger" <<'NODE'
const fs = require('fs');
const ledger = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (ledger.schema !== 'clasp-task-workspace-promotion-ledger-v1') throw new Error('bad manager promotion ledger schema');
if (ledger.status !== 'conflict' || ledger.conflicted !== true) throw new Error('expected manager promotion conflict ledger');
if (!ledger.filesSkippedDueToConflict.includes('workspace.txt')) throw new Error('manager promotion ledger missing workspace conflict');
if (!ledger.changesSkippedDueToConflict.some((change) => change.path === 'workspace.txt' && change.action === 'modify')) throw new Error('manager promotion ledger missing workspace modify conflict action');
if (!ledger.baseline?.fingerprint?.startsWith('sha256:')) throw new Error('manager promotion ledger missing baseline fingerprint');
if (!ledger.workspace?.fingerprint?.startsWith('sha256:')) throw new Error('manager promotion ledger missing workspace fingerprint');
if (!ledger.baseline?.manifest || !ledger.workspace?.manifest) throw new Error('manager promotion ledger missing stable manifest evidence fields');
if (!ledger.recoverableDiffPath || !fs.existsSync(ledger.recoverableDiffPath)) throw new Error('manager promotion ledger missing recoverable diff');
NODE
if grep -F '"summary":"planned task reconciliation failed"' "$promotion_conflict_state/feedback.json" >/dev/null 2>&1; then
  echo "promotion conflicts should be task-level recoverable failures, not manager reconciliation failures" >&2
  exit 1
fi

trace_case "stale-service-record-restart"
stale_service_state="$test_root_abs/stale-service-state"
stale_service_workspace="$test_root_abs/stale-service-workspace"
stale_service_root="$stale_service_state/service"
stale_run_root="$stale_service_root/runs/run-stale"
stale_heartbeat="$stale_run_root/service.heartbeat.json"
stale_output="$test_root_abs/stale-service-output.txt"
mkdir -p "$stale_service_workspace" "$stale_run_root"

cat >"$stale_heartbeat" <<JSON
{"completed":false,"exitCode":-1,"heartbeatPath":"$stale_heartbeat","pid":0,"running":true,"stderrPath":"$stale_run_root/service.stderr.log","stdoutPath":"$stale_run_root/service.stdout.log","updatedAtMs":0}
JSON
cat >"$stale_service_root/service.json" <<JSON
{"exitCode":-1,"generation":99,"heartbeatPath":"$stale_heartbeat","ownerPid":0,"serviceId":"goal-manager","serviceRoot":"$stale_service_root","snapshotPath":"","status":"active","transactionPath":"$stale_service_root/supervisor.config.json","updatedAtMs":0}
JSON

run_goal_manager "$stale_service_state" "$stale_service_workspace" \
  CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' \
  CLASP_MANAGER_MAX_WAVES_JSON='1' \
  >"$stale_output" 2>&1 &
goal_manager_live_pid=$!
if ! wait_for_path_contains "$stale_service_state/status.json" '"phase":"completed"' "" 1200 0.05; then
  wait_or_kill_pid "$goal_manager_live_pid" 100
  goal_manager_live_pid=""
  echo "timed out waiting for stale service restart regression" >&2
  sed -n '1,120p' "$stale_output" >&2 || true
  exit 1
fi
wait_or_kill_pid "$goal_manager_live_pid" 100
goal_manager_live_pid=""
stale_result="$(run_goal_manager_status "$stale_service_state" "$stale_service_workspace" CLASP_TEST_FAKE_PLANNER_MODE='benchmark-replan' CLASP_MANAGER_MAX_WAVES_JSON='1')"
printf '%s\n' "$stale_result" >"$stale_output.status"
grep -F '"phase":"completed"' "$stale_output.status" >/dev/null
grep -F '"verdict":"pass"' "$stale_output.status" >/dev/null
wait_for_path_contains "$stale_service_root/service.json" '"status":"completed"' "" 1200 0.05
grep -E '"generation":[1-9][0-9]*' "$stale_service_root/service.json" >/dev/null
if grep -F '"generation":99' "$stale_service_root/service.json" >/dev/null 2>&1; then
  echo "stale service generation should be replaced during restart" >&2
  exit 1
fi
grep -F '"completed":true' "$stale_heartbeat" >/dev/null
grep -F '"running":false' "$stale_heartbeat" >/dev/null
fi

printf 'goal-manager-fast-ok\n'
