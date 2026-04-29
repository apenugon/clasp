#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
export TMPDIR="$tmp_root"

test_root="$(mktemp -d "$TMPDIR/test-goal-manager-planner-memory.XXXXXX")"
test_root_abs="$(cd "$test_root" && pwd -P)"
state_root="$test_root_abs/state"
workspace_root="$test_root_abs/workspace"
goal_manager_binary="${CLASP_GOAL_MANAGER_BINARY:-$project_root/.clasp-loops/.cache/goal-manager-planner-memory/swarm-goal-manager}"
fake_codex_bin="$test_root_abs/codex"
fake_child_claspc_bin="$test_root_abs/fake-claspc"
fake_benchmark_bin="$test_root_abs/fake-benchmark"
output_path="$test_root_abs/output.txt"

cleanup() {
  local status="$1"
  set +e
  if [[ "$status" -ne 0 ]]; then
    if [[ -f "$output_path" ]]; then
      sed -n '1,200p' "$output_path" >&2 || true
    fi
    if [[ -f "$state_root/status.json" ]]; then
      sed -n '1,120p' "$state_root/status.json" >&2 || true
    fi
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
trap 'cleanup $?' EXIT

mkdir -p "$workspace_root"

cat > "$fake_codex_bin" <<'FAKECODEX'
#!/usr/bin/env bash
set -euo pipefail

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

if [[ -z "$report_path" ]]; then
  printf 'missing report path\n' >&2
  exit 1
fi

if [[ "$prompt" != *"Goal:"* ]]; then
  printf 'unexpected non-planner prompt\n' >&2
  exit 2
fi

if [[ "$prompt" == *"Wave: 5"* ]]; then
  [[ "$prompt" == *"Cross-wave memory:"* ]] || { printf 'missing cross-wave memory section\n' >&2; exit 40; }
  [[ "$prompt" == *"Prioritized backlog:"* ]] || { printf 'missing prioritized backlog section\n' >&2; exit 41; }
  [[ "$prompt" == *"No prior wave memory is available yet."* ]] || { printf 'missing planner memory scaffold text\n' >&2; exit 42; }
  [[ "$prompt" == *"No prioritized backlog is available yet."* ]] || { printf 'missing planner backlog scaffold text\n' >&2; exit 43; }
fi

cat > "$report_path" <<'JSON'
{"objectiveSummary":"Keep closing the benchmark gap.","strategy":"Run one bounded benchmark wave at a time and re-evaluate.","tasks":[{"taskId":"benchmark-gap","role":"benchmark-operator","detail":"Close the next benchmark gap.","dependencies":[],"taskPrompt":"Make the next bounded improvement toward the benchmark target.","coordinationFocus":["benchmark-gap","planner-memory"]}],"testsRun":["fake planner"],"residualRisks":["benchmark target not met yet"]}
JSON
FAKECODEX
chmod +x "$fake_codex_bin"

cat > "$fake_child_claspc_bin" <<'FAKECHILD'
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

workspace_root="${CLASP_LOOP_WORKSPACE_JSON:-}"
workspace_root="${workspace_root%\"}"
workspace_root="${workspace_root#\"}"
task_loop="$(basename "$state_root")"
task_id="${task_loop#loop-}"

mkdir -p "$workspace_root/notes" "$state_root"
printf '%s\n' "done-$task_id" > "$workspace_root/workspace.txt"
printf '%s\n' "done-$task_id" > "$workspace_root/notes/child-artifact.txt"

cat > "$state_root/state.json" <<'JSON'
{"attempt":1,"phase":"completed","verdict":"pass","completed":true,"builderRuns":1,"verifierRuns":1,"healthy":true,"needsAttention":false,"attentionReason":"","final":true}
JSON
cat > "$state_root/builder-1.json" <<JSON
{"summary":"fake child builder report for $task_id","files_touched":["workspace.txt","notes/child-artifact.txt"],"tests_run":["fake child builder"],"residual_risks":["keep benchmark pressure on the next wave"],"feedback":{"summary":"builder mailbox details for $task_id","ergonomics":["ordinary loop state stays durable"],"follow_ups":["reuse mailbox context for $task_id"],"warnings":[]}}
JSON
cat > "$state_root/feedback.json" <<JSON
{"verdict":"pass","summary":"fake child loop completed for $task_id","findings":["carry-forward finding for $task_id"],"tests_run":["fake child loop"],"follow_up":["reuse mailbox context for $task_id"],"capability_statuses":[{"name":"ordinary_program_execution","status":"pass","evidence":["fake child loop completed"],"blocking_gaps":[],"required_closure":[]}]}
JSON
printf 'fake child loop completed\n'
FAKECHILD
chmod +x "$fake_child_claspc_bin"

cat > "$fake_benchmark_bin" <<'FAKEBENCH'
#!/usr/bin/env bash
set -euo pipefail

wave="${CLASP_MANAGER_BENCHMARK_WAVE:-1}"
if [[ "$wave" == "5" ]]; then
  cat <<'JSON'
{"suite":"appbench","summary":"wave 5 benchmark meets target.","passed":true,"meetsTarget":true,"scoreName":"timeToGreenMs","scoreValue":100,"targetName":"maxTimeToGreenMs","targetValue":120}
JSON
else
  cat <<JSON
{"suite":"appbench","summary":"wave $wave benchmark still misses target.","passed":true,"meetsTarget":false,"scoreName":"timeToGreenMs","scoreValue":140,"targetName":"maxTimeToGreenMs","targetValue":120}
JSON
fi
FAKEBENCH
chmod +x "$fake_benchmark_bin"

if [[ -n "${CLASP_GOAL_MANAGER_BINARY:-}" ]]; then
  [[ -x "$goal_manager_binary" ]] || {
    printf 'CLASP_GOAL_MANAGER_BINARY is not executable: %s\n' "$goal_manager_binary" >&2
    exit 1
  }
else
  "$project_root/scripts/ensure-goal-manager-binary.sh" --alias "$goal_manager_binary" >/dev/null
fi

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
  CLASP_LOOP_CODEX_BIN_JSON="\"$fake_codex_bin\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$workspace_root\"" \
  CLASP_MANAGER_CLASPC_BIN_JSON="\"$fake_child_claspc_bin\"" \
  CLASP_MANAGER_GOAL_JSON='"Build durable cross-wave planner memory."' \
  CLASP_MANAGER_MAX_TASKS_JSON='1' \
  CLASP_MANAGER_MAX_WAVES_JSON='5' \
  CLASP_LOOP_WATCH_POLL_MS_JSON='25' \
  CLASP_MANAGER_BENCHMARK_POLL_MS_JSON='25' \
  CLASP_MANAGER_BENCHMARK_TIMEOUT_MS_JSON='10000' \
  CLASP_MANAGER_BENCHMARK_COMMAND_JSON="[\"$fake_benchmark_bin\"]" \
  CLASP_MANAGER_TRACE_JSON='true' \
  "$goal_manager_binary" "$state_root" > "$output_path" 2>&1

grep -F '"phase":"completed"' "$state_root/status.json" >/dev/null
grep -F '"verdict":"pass"' "$state_root/status.json" >/dev/null
test -f "$state_root/planner-memory-2.md"
test -f "$state_root/planner-backlog-2.md"
test -f "$state_root/planner-memory-5.md"
test -f "$state_root/planner-backlog-5.md"

grep -F 'No prior wave memory is available yet.' "$state_root/planner-memory-5.md" >/dev/null
grep -F 'No prioritized backlog is available yet.' "$state_root/planner-backlog-5.md" >/dev/null
grep -F 'No prior wave memory is available yet.' "$state_root/planner-memory-latest.md" >/dev/null
grep -F 'No prioritized backlog is available yet.' "$state_root/planner-backlog-latest.md" >/dev/null

grep -F 'resume-manager:phase=needs-planner:wave=2:benchmark-runs=1' "$state_root/trace.log" >/dev/null
grep -F 'resume-manager:phase=needs-planner:wave=5:benchmark-runs=4' "$state_root/trace.log" >/dev/null

printf 'goal-manager-planner-memory-ok\n'
