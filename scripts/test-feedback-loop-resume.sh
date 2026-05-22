#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-feedback-loop-resume.XXXXXX")"
test_root_abs="$(cd "$test_root" && pwd -P)"
export XDG_CACHE_HOME="$test_root_abs/xdg-cache"
# This fixture asserts focused verifier resume behavior. Parent swarm verifiers
# may export a full-signoff tier, so pin the scenario explicitly.
export CLASP_LOOP_VERIFICATION_TIER_JSON='"focused"'
export CLASP_TEST_REJECT_CODEX_PROMPT_ARG=1
requested_cases=("$@")

usage() {
  cat <<'EOF'
usage: scripts/test-feedback-loop-resume.sh [case-or-group ...]

With no arguments, runs the complete resume harness. Focused verifier routes can
run a smaller scenario:
  smoke              loop routing plus missing-baseline fail-closed guard
  routing            all diff-derived focused routing scenarios
  manager-env        manager string/list command override scenarios
  failure            oversized feedback, missing report, and missing baseline guards
  manager-string     verifier resume with a manager string command
  builder-stdin      builder/verifier prompts are streamed through stdin
  oversized-feedback previous verifier feedback compaction
  no-report          zero-exit verifier without a durable report fails closed
  manager-list       manager JSON list command override
  loop-routing       loop-only diff selects loop-focused checks
  native-routing     native scenario diff selects native scenario checks
  goal-helper-routing GoalManager helper diff selects control-plane checks
  speed-routing      compiler speed diff selects incremental checks
  verify-routing     verifier harness diff selects verifier harness checks
  unknown-routing    unknown diff falls back to verify-fast
  missing-baseline   externally supplied missing baseline fails closed
EOF
}

case_matches() {
  local requested="$1"
  local candidate="$2"

  case "$requested" in
    all)
      return 0
      ;;
    smoke)
      [[ "$candidate" == "loop-routing" || "$candidate" == "missing-baseline" ]]
      return $?
      ;;
    routing)
      [[ "$candidate" == "loop-routing" || "$candidate" == "native-routing" || "$candidate" == "goal-helper-routing" || "$candidate" == "speed-routing" || "$candidate" == "verify-routing" || "$candidate" == "unknown-routing" ]]
      return $?
      ;;
    manager-env)
      [[ "$candidate" == "manager-string" || "$candidate" == "manager-list" ]]
      return $?
      ;;
    failure)
      [[ "$candidate" == "oversized-feedback" || "$candidate" == "no-report" || "$candidate" == "missing-baseline" ]]
      return $?
      ;;
    manager-string|builder-stdin|oversized-feedback|no-report|manager-list|loop-routing|native-routing|goal-helper-routing|speed-routing|verify-routing|unknown-routing|missing-baseline)
      [[ "$candidate" == "$requested" ]]
      return $?
      ;;
    *)
      return 1
      ;;
  esac
}

case_enabled() {
  local candidate="$1"
  local requested=""

  if (( ${#requested_cases[@]} == 0 )); then
    return 0
  fi

  for requested in "${requested_cases[@]}"; do
    if case_matches "$requested" "$candidate"; then
      return 0
    fi
  done
  return 1
}

for requested_case in "${requested_cases[@]}"; do
  case "$requested_case" in
    --help|-h)
      usage
      exit 0
      ;;
    all|smoke|routing|manager-env|failure|manager-string|builder-stdin|oversized-feedback|no-report|manager-list|loop-routing|native-routing|goal-helper-routing|speed-routing|verify-routing|unknown-routing|missing-baseline)
      ;;
    *)
      printf 'test-feedback-loop-resume: unknown case or group: %s\n' "$requested_case" >&2
      usage >&2
      exit 2
      ;;
  esac
done

cleanup() {
  if [[ "${CLASP_TEST_KEEP_TMP:-}" == "1" ]]; then
    printf 'kept test root: %s\n' "$test_root_abs" >&2
  else
    rm -rf "$test_root" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"
fake_codex_bin="$test_root_abs/codex"
task_file="$test_root_abs/task.md"
fixture_project="$test_root_abs/project"
state_root="$test_root_abs/loop-resume-state"
workspace_root="$fixture_project/.clasp-task-workspaces/resume-task"
baseline_root="$fixture_project/.clasp-task-baselines/resume-task"
diff_path="$state_root/changes-1.diff"

mkdir -p "$fixture_project" "$state_root" "$workspace_root" "$baseline_root"
printf 'Resume verifier from an externally supplied task baseline.\n' >"$task_file"

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
    -o)
      report_path="$2"
      shift 2
      ;;
    *)
      if [[ "${CLASP_TEST_REJECT_CODEX_PROMPT_ARG:-0}" == "1" && "$1" != "-" ]]; then
        printf 'codex prompt was passed as argv instead of stdin\n' >&2
        exit 91
      fi
      prompt="$1"
      shift
      ;;
  esac
done

if [[ "$prompt" == "-" ]]; then
  prompt="$(cat)"
fi

if [[ -n "${CLASP_TEST_PROMPT_CAPTURE:-}" ]]; then
  printf '%s' "$prompt" >"$CLASP_TEST_PROMPT_CAPTURE"
fi

if [[ -n "${CLASP_TEST_BUILDER_PROMPT_CAPTURE:-}" && "$prompt" == *"builder subagent"* ]]; then
  printf '%s' "$prompt" >"$CLASP_TEST_BUILDER_PROMPT_CAPTURE"
fi

if [[ -n "${CLASP_TEST_VERIFIER_PROMPT_CAPTURE:-}" && "$prompt" == *"verifier subagent"* ]]; then
  printf '%s' "$prompt" >"$CLASP_TEST_VERIFIER_PROMPT_CAPTURE"
fi

if [[ -z "$report_path" ]]; then
  printf 'missing report path\n' >&2
  exit 2
fi

state_root="$(dirname "$report_path")"
mkdir -p "$state_root"

if [[ "$prompt" == *"builder subagent"* ]]; then
  if [[ "${CLASP_TEST_ALLOW_BUILDER_STDIN:-0}" == "1" ]]; then
    printf 'builder\n' >>"$state_root/codex-invocations.log"
    cat >"$report_path" <<'JSON'
{"summary":"builder read prompt from stdin","files_touched":[],"tests_run":["fake builder stdin"],"residual_risks":[],"feedback":{"summary":"builder prompt was streamed through stdin","ergonomics":[],"follow_ups":[],"warnings":[]}}
JSON
    exit 0
  fi
  printf 'builder was re-run during verifier resume\n' >"$state_root/builder-reran.marker"
  exit 65
fi

if [[ "$prompt" != *"verifier subagent"* ]]; then
  printf 'unexpected fake codex prompt\n' >&2
  exit 66
fi

if [[ "$prompt" == *"Run the full signoff command before reporting pass:"* ]]; then
  printf 'focused verifier prompt unexpectedly demanded full signoff\n' >&2
  exit 68
fi

if ! compgen -G "$state_root/changes-*.diff" >/dev/null; then
  printf 'missing refreshed baseline diff before verifier launch\n' >&2
  exit 67
fi

if [[ "${CLASP_TEST_EXPECT_MANAGER_STRING_COMMANDS:-0}" == "1" ]]; then
  if [[ "$prompt" != *"Focused verification command source: manager-env"* ]]; then
    printf 'verifier prompt did not mark manager string commands as authoritative\n' >&2
    exit 69
  fi
  if [[ "$prompt" != *"runtime/target/debug/claspc --json check examples/feedback-loop/Main.clasp; bash scripts/test-swarm-ready-gate.sh"* ]]; then
    printf 'verifier prompt did not preserve manager JSON string command text\n' >&2
    exit 70
  fi
fi

if [[ "${CLASP_TEST_EXPECT_MANAGER_LIST_COMMANDS:-0}" == "1" ]]; then
  if [[ "$prompt" != *"Focused verification command source: manager-env"* ]]; then
    printf 'verifier prompt did not mark manager list commands as authoritative\n' >&2
    exit 71
  fi
  if [[ "$prompt" != *"bash scripts/test-feedback-loop-resume.sh"* || "$prompt" != *"bash scripts/test-swarm-ready-gate.sh"* ]]; then
    printf 'verifier prompt did not preserve manager JSON list commands\n' >&2
    exit 72
  fi
  if [[ "$prompt" == *"bash scripts/verify-fast.sh"* ]]; then
    printf 'manager list commands were unexpectedly replaced by diff-derived verify-fast\n' >&2
    exit 73
  fi
fi

if [[ "${CLASP_TEST_EXPECT_DERIVED_LOOP_COMMANDS:-0}" == "1" ]]; then
  if [[ "$prompt" != *"Focused verification command source: diff-derived"* ]]; then
    printf 'verifier prompt did not mark loop commands as diff-derived\n' >&2
    exit 74
  fi
  if [[ "$prompt" != *"bash scripts/test-feedback-loop-resume.sh loop-routing"* || "$prompt" != *"bash scripts/test-swarm-ready-gate.sh"* ]]; then
    printf 'verifier prompt did not select loop-focused checks from the diff\n' >&2
    exit 75
  fi
  if [[ "$prompt" == *"bash scripts/verify-fast.sh"* ]]; then
    printf 'loop-only diff unexpectedly fell back to verify-fast\n' >&2
    exit 76
  fi
fi

if [[ "${CLASP_TEST_EXPECT_DERIVED_NATIVE_COMMANDS:-0}" == "1" ]]; then
  if [[ "$prompt" != *"Focused verification command source: diff-derived"* ]]; then
    printf 'verifier prompt did not mark native scenario commands as diff-derived\n' >&2
    exit 80
  fi
  if [[ "$prompt" != *'$(scripts/resolve-claspc.sh) --json check examples/swarm-native/Main.clasp'* || "$prompt" != *"bash scripts/test-native-claspc.sh"* ]]; then
    printf 'verifier prompt did not select native scenario checks from the diff\n' >&2
    exit 81
  fi
  if [[ "$prompt" == *"bash scripts/test-goal-manager-fast.sh"* ]]; then
    printf 'native scenario diff unexpectedly selected goal-manager fast test\n' >&2
    exit 82
  fi
  if [[ "$prompt" == *"bash scripts/verify-fast.sh"* ]]; then
    printf 'native scenario diff unexpectedly fell back to verify-fast\n' >&2
    exit 83
  fi
fi

if [[ "${CLASP_TEST_EXPECT_DERIVED_GOAL_MANAGER_HELPER_COMMANDS:-0}" == "1" ]]; then
  if [[ "$prompt" != *"Focused verification command source: diff-derived"* ]]; then
    printf 'verifier prompt did not mark GoalManager helper commands as diff-derived\n' >&2
    exit 90
  fi
  if [[ "$prompt" != *'$(scripts/resolve-claspc.sh) --json check examples/swarm-native/GoalManager.clasp'* || "$prompt" != *"bash scripts/test-goal-manager-fast.sh"* ]]; then
    printf 'verifier prompt did not select GoalManager control-plane checks from the helper diff\n' >&2
    exit 91
  fi
  if [[ "$prompt" == *"unknown_path"* ]]; then
    printf 'GoalManager helper diff was misclassified as unknown\n' >&2
    exit 92
  fi
  if [[ "$prompt" == *"bash scripts/verify-fast.sh"* ]]; then
    printf 'GoalManager helper diff unexpectedly fell back to verify-fast\n' >&2
    exit 93
  fi
fi

if [[ "${CLASP_TEST_EXPECT_DERIVED_SPEED_COMMANDS:-0}" == "1" ]]; then
  if [[ "$prompt" != *"Focused verification command source: diff-derived"* ]]; then
    printf 'verifier prompt did not mark compiler speed commands as diff-derived\n' >&2
    exit 84
  fi
  if [[ "$prompt" != *"bash scripts/test-native-incremental-guard.sh"* || "$prompt" != *"node --check scripts/native-incremental-guard.mjs"* ]]; then
    printf 'verifier prompt did not select compiler speed checks from the diff\n' >&2
    exit 85
  fi
  if [[ "$prompt" == *"bash scripts/verify-fast.sh"* ]]; then
    printf 'compiler speed diff unexpectedly fell back to verify-fast\n' >&2
    exit 86
  fi
fi

if [[ "${CLASP_TEST_EXPECT_DERIVED_VERIFY_HARNESS_COMMANDS:-0}" == "1" ]]; then
  if [[ "$prompt" != *"Focused verification command source: diff-derived"* ]]; then
    printf 'verifier prompt did not mark verifier harness commands as diff-derived\n' >&2
    exit 87
  fi
  if [[ "$prompt" != *"bash scripts/test-verify-all.sh"* || "$prompt" != *"bash scripts/test-swarm-ready-gate.sh"* ]]; then
    printf 'verifier prompt did not select verifier-harness checks from the diff\n' >&2
    exit 88
  fi
  if [[ "$prompt" == *"bash scripts/verify-fast.sh"* ]]; then
    printf 'verifier harness diff unexpectedly fell back to verify-fast\n' >&2
    exit 89
  fi
fi

if [[ "${CLASP_TEST_EXPECT_UNKNOWN_VERIFY_FAST:-0}" == "1" ]]; then
  if [[ "$prompt" != *"Focused verification command source: diff-derived"* ]]; then
    printf 'verifier prompt did not mark unknown commands as diff-derived\n' >&2
    exit 77
  fi
  if [[ "$prompt" != *"diff included unknown paths; selected conservative verify-fast"* ]]; then
    printf 'verifier prompt did not explain unknown diff fallback\n' >&2
    exit 78
  fi
  if [[ "$prompt" != *"bash scripts/verify-fast.sh"* ]]; then
    printf 'unknown diff did not select verify-fast\n' >&2
    exit 79
  fi
fi

printf 'verifier\n' >>"$state_root/codex-invocations.log"
cat >"$report_path" <<'JSON'
{"verdict":"pass","summary":"resumed verifier produced a durable report","findings":["verifier-step-ready resumed without re-running builder"],"tests_run":["feedback-loop resume fixture"],"follow_up":[],"capability_statuses":[{"name":"ordinary_program_execution","status":"pass","evidence":["claspc run resumed a normal feedback-loop program at verifier-step-ready"],"blocking_gaps":[],"required_closure":[]},{"name":"verification_gate","status":"pass","evidence":["scenario seeded a verifier-ready state and observed a durable verifier report"],"blocking_gaps":[],"required_closure":[]}]}
JSON
EOF
chmod +x "$fake_codex_bin"

printf 'base\n' >"$baseline_root/workspace.txt"
mkdir -p "$baseline_root/notes"
printf 'base-artifact\n' >"$baseline_root/notes/child-artifact.txt"
cp -a "$baseline_root/." "$workspace_root/"
printf 'builder-change\n' >"$workspace_root/workspace.txt"
printf 'builder-artifact\n' >"$workspace_root/notes/child-artifact.txt"
printf 'ready\n' >"$workspace_root/.workspace-ready"
mkdir -p \
  "$workspace_root/benchmarks/bundles" \
  "$workspace_root/benchmarks/workspaces/generated" \
  "$workspace_root/benchmarks/results" \
  "$workspace_root/.clasp-task-baselines/nested" \
  "$workspace_root/.clasp-task-workspaces/nested"
printf 'bundle-noise\n' >"$workspace_root/benchmarks/bundles/bundle-noise.json"
printf 'workspace-noise\n' >"$workspace_root/benchmarks/workspaces/generated/generated-workspace-noise.txt"
printf 'result-noise\n' >"$workspace_root/benchmarks/results/benchmark-result-noise.txt"
printf 'nested-baseline-noise\n' >"$workspace_root/.clasp-task-baselines/nested/nested-baseline-noise.txt"
printf 'nested-workspace-noise\n' >"$workspace_root/.clasp-task-workspaces/nested/nested-workspace-noise.txt"

cat >"$state_root/state.json" <<'JSON'
{"attempt":1,"phase":"verifier-step-ready","verdict":"pending","completed":false,"builderRuns":1,"verifierRuns":1,"healthy":true,"needsAttention":false,"attentionReason":"","final":false}
JSON
cat >"$state_root/builder-1.json" <<'JSON'
{"summary":"builder completed before verifier resume","files_touched":["workspace.txt","notes/child-artifact.txt"],"tests_run":[],"residual_risks":[],"feedback":{"summary":"resume at verifier","ergonomics":[],"follow_ups":[],"warnings":[]}}
JSON
printf 'ready\n' >"$state_root/baseline.ready"

if case_enabled manager-string; then
resume_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$fake_codex_bin\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$workspace_root\"" \
  CLASP_LOOP_BASELINE_WORKSPACE_JSON="\"$baseline_root\"" \
  CLASP_LOOP_FOCUSED_VERIFY_COMMANDS_JSON='"runtime/target/debug/claspc --json check examples/feedback-loop/Main.clasp; bash scripts/test-swarm-ready-gate.sh"' \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='1' \
  CLASP_TEST_EXPECT_MANAGER_STRING_COMMANDS='1' \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$state_root"
)"

printf '%s\n' "$resume_output" | grep -Fx 'pass:1' >/dev/null
test -f "$state_root/verifier-1.json"
test -f "$state_root/verifier-1.prompt.md"
test -f "$state_root/focused-verify-1.json"
grep -F '"source":"manager-env"' "$state_root/focused-verify-1.json" >/dev/null
grep -F '"changedSurfaceCategories"' "$state_root/focused-verify-1.json" >/dev/null
grep -F 'manager_env_override' "$state_root/focused-verify-1.json" >/dev/null
grep -F '"cacheEvidence"' "$state_root/focused-verify-1.json" >/dev/null
grep -F 'runtime/claspc.rs emits [claspc-cache]' "$state_root/focused-verify-1.json" >/dev/null
grep -F 'runtime/target/debug/claspc --json check examples/feedback-loop/Main.clasp; bash scripts/test-swarm-ready-gate.sh' "$state_root/focused-verify-1.json" >/dev/null
grep -F '"summary":"resumed verifier produced a durable report"' "$state_root/verifier-1.json" >/dev/null
grep -F '"phase":"completed"' "$state_root/state.json" >/dev/null
grep -F '"verdict":"pass"' "$state_root/feedback.json" >/dev/null
grep -Fx 'verifier' "$state_root/codex-invocations.log" >/dev/null
test ! -e "$state_root/builder-reran.marker"

grep -Fx 'base' "$baseline_root/workspace.txt" >/dev/null
grep -Fx 'base-artifact' "$baseline_root/notes/child-artifact.txt" >/dev/null
test -f "$diff_path"
grep -F 'workspace.txt' "$diff_path" >/dev/null
grep -F 'notes/child-artifact.txt' "$diff_path" >/dev/null

for unexpected in \
  '.workspace-ready' \
  'bundle-noise.json' \
  'generated-workspace-noise.txt' \
  'benchmark-result-noise.txt' \
  'nested-baseline-noise.txt' \
  'nested-workspace-noise.txt'
do
  if grep -E '^(---|\+\+\+) ' "$diff_path" | grep -F "$unexpected" >/dev/null; then
    printf 'resume diff unexpectedly included generated noise: %s\n' "$unexpected" >&2
    sed -n '1,120p' "$diff_path" >&2
    exit 1
  fi
done

fi

builder_stdin_state_root="$test_root_abs/loop-builder-stdin-state"
builder_stdin_workspace_root="$fixture_project/.clasp-task-workspaces/builder-stdin-task"
builder_stdin_baseline_root="$fixture_project/.clasp-task-baselines/builder-stdin-task"
mkdir -p "$builder_stdin_state_root" "$builder_stdin_workspace_root" "$builder_stdin_baseline_root"
printf 'builder stdin baseline\n' >"$builder_stdin_baseline_root/workspace.txt"
cp -a "$builder_stdin_baseline_root/." "$builder_stdin_workspace_root/"

if case_enabled builder-stdin; then
builder_stdin_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$fake_codex_bin\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$builder_stdin_workspace_root\"" \
  CLASP_LOOP_BASELINE_WORKSPACE_JSON="\"$builder_stdin_baseline_root\"" \
  CLASP_LOOP_FOCUSED_VERIFY_COMMANDS_JSON='"bash scripts/test-feedback-loop-resume.sh"' \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='1' \
  CLASP_TEST_ALLOW_BUILDER_STDIN='1' \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$builder_stdin_state_root"
)"

printf '%s\n' "$builder_stdin_output" | grep -Fx 'pass:1' >/dev/null
test -f "$builder_stdin_state_root/builder-1.prompt.md"
test -f "$builder_stdin_state_root/verifier-1.prompt.md"
grep -Fx 'builder' "$builder_stdin_state_root/codex-invocations.log" >/dev/null
grep -Fx 'verifier' "$builder_stdin_state_root/codex-invocations.log" >/dev/null

fi

oversized_feedback_state_root="$test_root_abs/loop-oversized-feedback-state"
oversized_feedback_workspace_root="$fixture_project/.clasp-task-workspaces/oversized-feedback-task"
oversized_feedback_baseline_root="$fixture_project/.clasp-task-baselines/oversized-feedback-task"
oversized_feedback_prompt="$test_root_abs/oversized-builder.prompt"
mkdir -p "$oversized_feedback_state_root" "$oversized_feedback_workspace_root" "$oversized_feedback_baseline_root"
printf 'oversized feedback baseline\n' >"$oversized_feedback_baseline_root/workspace.txt"
cp -a "$oversized_feedback_baseline_root/." "$oversized_feedback_workspace_root/"
cat >"$oversized_feedback_state_root/state.json" <<'JSON'
{"attempt":2,"phase":"needs-builder","verdict":"retry","completed":false,"builderRuns":1,"verifierRuns":1,"healthy":false,"needsAttention":true,"attentionReason":"verifier did not pass","final":false}
JSON
printf 'ready\n' >"$oversized_feedback_state_root/baseline.ready"
node - "$oversized_feedback_state_root/feedback.json" <<'NODE'
const fs = require('node:fs');
const feedbackPath = process.argv[2];
const huge = 'X'.repeat(1500000);
fs.writeFileSync(feedbackPath, JSON.stringify({
  verdict: 'fail',
  summary: 'oversized verifier stdout should be compacted',
  findings: [`stdout_tail=${huge}`],
  tests_run: [],
  follow_up: ['inspect bounded log artifacts'],
  capability_statuses: []
}));
NODE

if case_enabled oversized-feedback; then
oversized_feedback_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$fake_codex_bin\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$oversized_feedback_workspace_root\"" \
  CLASP_LOOP_BASELINE_WORKSPACE_JSON="\"$oversized_feedback_baseline_root\"" \
  CLASP_LOOP_FOCUSED_VERIFY_COMMANDS_JSON='"bash scripts/test-feedback-loop-resume.sh"' \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='2' \
  CLASP_LOOP_FEEDBACK_PROMPT_MAX_CHARS_JSON='1000' \
  CLASP_TEST_ALLOW_BUILDER_STDIN='1' \
  CLASP_TEST_BUILDER_PROMPT_CAPTURE="$oversized_feedback_prompt" \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$oversized_feedback_state_root"
)"

printf '%s\n' "$oversized_feedback_output" | grep -Fx 'pass:2' >/dev/null
test -f "$oversized_feedback_prompt"
test "$(wc -c <"$oversized_feedback_prompt")" -lt 20000
grep -F 'Verifier feedback from the previous attempt was compacted because the raw feedback exceeded the prompt budget.' "$oversized_feedback_prompt" >/dev/null
grep -F 'oversized verifier stdout should be compacted' "$oversized_feedback_prompt" >/dev/null
if grep -F 'stdout_tail=XXXXXXXXXXXXXXXX' "$oversized_feedback_prompt" >/dev/null; then
  printf 'oversized feedback leaked raw stdout into the builder prompt\n' >&2
  exit 1
fi

fi

no_report_state_root="$test_root_abs/loop-no-report-zero-state"
no_report_workspace_root="$fixture_project/.clasp-task-workspaces/no-report-zero-task"
no_report_baseline_root="$fixture_project/.clasp-task-baselines/no-report-zero-task"
mkdir -p "$no_report_state_root" "$no_report_workspace_root" "$no_report_baseline_root"
printf 'base\n' >"$no_report_baseline_root/workspace.txt"
cp -a "$no_report_baseline_root/." "$no_report_workspace_root/"
printf 'no-report-change\n' >"$no_report_workspace_root/workspace.txt"
cat >"$no_report_state_root/state.json" <<'JSON'
{"attempt":1,"phase":"verifier-running","verdict":"pending","completed":false,"builderRuns":1,"verifierRuns":1,"healthy":true,"needsAttention":false,"attentionReason":"","final":false}
JSON
cat >"$no_report_state_root/builder-1.json" <<'JSON'
{"summary":"builder completed before verifier transport reported success without a report","files_touched":["workspace.txt"],"tests_run":[],"residual_risks":[],"feedback":{"summary":"verifier transport completed without report","ergonomics":[],"follow_ups":[],"warnings":[]}}
JSON
printf 'ready\n' >"$no_report_state_root/baseline.ready"
node - "$no_report_state_root/verifier-1.stdout.jsonl" <<'NODE'
const fs = require('node:fs');
const path = process.argv[2];
fs.writeFileSync(path, `transport claimed success without writing verifier report\n${'Y'.repeat(20000)}`);
NODE
: >"$no_report_state_root/verifier-1.stderr.log"
cat >"$no_report_state_root/verifier-1.heartbeat.json" <<JSON
{"pid":0,"running":false,"completed":true,"exitCode":0,"stdoutPath":"$no_report_state_root/verifier-1.stdout.jsonl","stderrPath":"$no_report_state_root/verifier-1.stderr.log","heartbeatPath":"$no_report_state_root/verifier-1.heartbeat.json","updatedAtMs":0}
JSON

if case_enabled no-report; then
no_report_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$fake_codex_bin\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$no_report_workspace_root\"" \
  CLASP_LOOP_BASELINE_WORKSPACE_JSON="\"$no_report_baseline_root\"" \
  CLASP_LOOP_FOCUSED_VERIFY_COMMANDS_JSON='"runtime/target/debug/claspc --json check examples/feedback-loop/Main.clasp; bash scripts/test-swarm-ready-gate.sh"' \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='2' \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$no_report_state_root"
)"

printf '%s\n' "$no_report_output" | grep -Fx 'fail:1' >/dev/null
test -f "$no_report_state_root/feedback.json"
test ! -e "$no_report_state_root/verifier-1.json"
grep -F '"summary":"verifier step failed before producing a durable report"' "$no_report_state_root/feedback.json" >/dev/null
grep -F 'exit_status=0' "$no_report_state_root/feedback.json" >/dev/null
grep -F 'stdout_omitted=' "$no_report_state_root/feedback.json" >/dev/null
if grep -F 'YYYYYYYYYYYYYYYY' "$no_report_state_root/feedback.json" >/dev/null; then
  printf 'missing-report feedback leaked oversized verifier stdout\n' >&2
  exit 1
fi
grep -F '"phase":"failed"' "$no_report_state_root/state.json" >/dev/null
grep -F '"verdict":"fail"' "$no_report_state_root/state.json" >/dev/null
test ! -e "$no_report_state_root/builder-reran.marker"
if grep -F '"phase":"verifier-running"' "$no_report_state_root/state.json" >/dev/null; then
  printf 'zero-exit missing-report resume left state at verifier-running\n' >&2
  exit 1
fi

fi

manager_list_state_root="$test_root_abs/loop-manager-list-state"
manager_list_workspace_root="$fixture_project/.clasp-task-workspaces/manager-list-task"
manager_list_baseline_root="$fixture_project/.clasp-task-baselines/manager-list-task"
mkdir -p "$manager_list_state_root" "$manager_list_workspace_root" "$manager_list_baseline_root"
printf 'base\n' >"$manager_list_baseline_root/workspace.txt"
cp -a "$manager_list_baseline_root/." "$manager_list_workspace_root/"
printf 'manager-list-change\n' >"$manager_list_workspace_root/workspace.txt"
cat >"$manager_list_state_root/state.json" <<'JSON'
{"attempt":1,"phase":"verifier-step-ready","verdict":"pending","completed":false,"builderRuns":1,"verifierRuns":1,"healthy":true,"needsAttention":false,"attentionReason":"","final":false}
JSON
cat >"$manager_list_state_root/builder-1.json" <<'JSON'
{"summary":"builder completed before manager list verification","files_touched":["workspace.txt"],"tests_run":[],"residual_risks":[],"feedback":{"summary":"manager list commands","ergonomics":[],"follow_ups":[],"warnings":[]}}
JSON
printf 'ready\n' >"$manager_list_state_root/baseline.ready"

if case_enabled manager-list; then
manager_list_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$fake_codex_bin\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$manager_list_workspace_root\"" \
  CLASP_LOOP_BASELINE_WORKSPACE_JSON="\"$manager_list_baseline_root\"" \
  CLASP_LOOP_FOCUSED_VERIFY_COMMANDS_JSON='["bash scripts/test-feedback-loop-resume.sh","bash scripts/test-swarm-ready-gate.sh"]' \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='1' \
  CLASP_TEST_EXPECT_MANAGER_LIST_COMMANDS='1' \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$manager_list_state_root"
)"

printf '%s\n' "$manager_list_output" | grep -Fx 'pass:1' >/dev/null
test -f "$manager_list_state_root/focused-verify-1.json"
grep -F '"source":"manager-env"' "$manager_list_state_root/focused-verify-1.json" >/dev/null
grep -F 'manager_env_override' "$manager_list_state_root/focused-verify-1.json" >/dev/null
grep -F 'bash scripts/test-feedback-loop-resume.sh' "$manager_list_state_root/focused-verify-1.json" >/dev/null
grep -F 'bash scripts/test-swarm-ready-gate.sh' "$manager_list_state_root/focused-verify-1.json" >/dev/null
if grep -F 'bash scripts/verify-fast.sh' "$manager_list_state_root/focused-verify-1.json" >/dev/null; then
  printf 'manager list focused commands unexpectedly fell back to verify-fast\n' >&2
  exit 1
fi

fi

derived_loop_state_root="$test_root_abs/loop-derived-focused-state"
derived_loop_workspace_root="$fixture_project/.clasp-task-workspaces/derived-focused-task"
derived_loop_baseline_root="$fixture_project/.clasp-task-baselines/derived-focused-task"
mkdir -p \
  "$derived_loop_state_root" \
  "$derived_loop_workspace_root/examples/feedback-loop" \
  "$derived_loop_baseline_root/examples/feedback-loop"
printf 'base feedback loop\n' >"$derived_loop_baseline_root/examples/feedback-loop/Main.clasp"
cp -a "$derived_loop_baseline_root/." "$derived_loop_workspace_root/"
printf 'changed feedback loop\n' >"$derived_loop_workspace_root/examples/feedback-loop/Main.clasp"
mkdir -p "$derived_loop_workspace_root/runtime/target/debug"
printf 'Signature: 8a477f597d28d172789f06886806bc55\n' >"$derived_loop_workspace_root/runtime/target/CACHEDIR.TAG"
printf 'generated runtime build noise\n' >"$derived_loop_workspace_root/runtime/target/debug/generated.txt"
mkdir -p "$derived_loop_workspace_root/src/native-verify-cache/xdg/generated"
printf 'generated native verify cache noise\n' >"$derived_loop_workspace_root/src/native-verify-cache/xdg/generated/cache.txt"
cat >"$derived_loop_state_root/state.json" <<'JSON'
{"attempt":1,"phase":"verifier-step-ready","verdict":"pending","completed":false,"builderRuns":1,"verifierRuns":1,"healthy":true,"needsAttention":false,"attentionReason":"","final":false}
JSON
cat >"$derived_loop_state_root/builder-1.json" <<'JSON'
{"summary":"builder changed feedback-loop program","files_touched":["examples/feedback-loop/Main.clasp"],"tests_run":[],"residual_risks":[],"feedback":{"summary":"derive focused loop commands","ergonomics":[],"follow_ups":[],"warnings":[]}}
JSON
printf 'ready\n' >"$derived_loop_state_root/baseline.ready"

if case_enabled loop-routing; then
derived_loop_output="$(
  env -u CLASP_LOOP_FOCUSED_VERIFY_COMMANDS_JSON \
  CLASP_LOOP_CODEX_BIN_JSON="\"$fake_codex_bin\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$derived_loop_workspace_root\"" \
  CLASP_LOOP_BASELINE_WORKSPACE_JSON="\"$derived_loop_baseline_root\"" \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='1' \
  CLASP_TEST_EXPECT_DERIVED_LOOP_COMMANDS='1' \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$derived_loop_state_root"
)"

printf '%s\n' "$derived_loop_output" | grep -Fx 'pass:1' >/dev/null
test -f "$derived_loop_state_root/focused-verify-1.json"
grep -F '"source":"diff-derived"' "$derived_loop_state_root/focused-verify-1.json" >/dev/null
grep -F 'feedback_loop' "$derived_loop_state_root/focused-verify-1.json" >/dev/null
grep -F '"fallbackReason":""' "$derived_loop_state_root/focused-verify-1.json" >/dev/null
grep -F 'bash scripts/test-feedback-loop-resume.sh loop-routing' "$derived_loop_state_root/focused-verify-1.json" >/dev/null
grep -F 'bash scripts/test-swarm-ready-gate.sh' "$derived_loop_state_root/focused-verify-1.json" >/dev/null
if grep -F 'bash scripts/verify-fast.sh' "$derived_loop_state_root/focused-verify-1.json" >/dev/null; then
  printf 'loop-only focused diff unexpectedly selected verify-fast\n' >&2
  exit 1
fi
if grep -E '^(---|\+\+\+) ' "$derived_loop_state_root/changes-1.diff" | grep -F 'runtime/target' >/dev/null; then
  printf 'loop-only focused diff unexpectedly included runtime/target noise\n' >&2
  sed -n '1,120p' "$derived_loop_state_root/changes-1.diff" >&2
  exit 1
fi
if grep -E '^(---|\+\+\+) ' "$derived_loop_state_root/changes-1.diff" | grep -F 'src/native-verify-cache' >/dev/null; then
  printf 'loop-only focused diff unexpectedly included native verify cache noise\n' >&2
  sed -n '1,120p' "$derived_loop_state_root/changes-1.diff" >&2
  exit 1
fi

fi

derived_native_state_root="$test_root_abs/loop-derived-native-focused-state"
derived_native_workspace_root="$fixture_project/.clasp-task-workspaces/derived-native-focused-task"
derived_native_baseline_root="$fixture_project/.clasp-task-baselines/derived-native-focused-task"
mkdir -p \
  "$derived_native_state_root" \
  "$derived_native_workspace_root/examples/swarm-native" \
  "$derived_native_baseline_root/examples/swarm-native"
printf 'base native scenario\n' >"$derived_native_baseline_root/examples/swarm-native/Swarm.clasp"
cp -a "$derived_native_baseline_root/." "$derived_native_workspace_root/"
printf 'changed native scenario\n' >"$derived_native_workspace_root/examples/swarm-native/Swarm.clasp"
cat >"$derived_native_state_root/state.json" <<'JSON'
{"attempt":1,"phase":"verifier-step-ready","verdict":"pending","completed":false,"builderRuns":1,"verifierRuns":1,"healthy":true,"needsAttention":false,"attentionReason":"","final":false}
JSON
cat >"$derived_native_state_root/builder-1.json" <<'JSON'
{"summary":"builder changed native swarm scenario API","files_touched":["examples/swarm-native/Swarm.clasp"],"tests_run":[],"residual_risks":[],"feedback":{"summary":"derive native scenario checks","ergonomics":[],"follow_ups":[],"warnings":[]}}
JSON
printf 'ready\n' >"$derived_native_state_root/baseline.ready"

if case_enabled native-routing; then
derived_native_output="$(
  env -u CLASP_LOOP_FOCUSED_VERIFY_COMMANDS_JSON \
  CLASP_LOOP_CODEX_BIN_JSON="\"$fake_codex_bin\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$derived_native_workspace_root\"" \
  CLASP_LOOP_BASELINE_WORKSPACE_JSON="\"$derived_native_baseline_root\"" \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='1' \
  CLASP_TEST_EXPECT_DERIVED_NATIVE_COMMANDS='1' \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$derived_native_state_root"
)"

printf '%s\n' "$derived_native_output" | grep -Fx 'pass:1' >/dev/null
test -f "$derived_native_state_root/focused-verify-1.json"
grep -F '"source":"diff-derived"' "$derived_native_state_root/focused-verify-1.json" >/dev/null
grep -F 'native_scenario' "$derived_native_state_root/focused-verify-1.json" >/dev/null
grep -F '"fallbackReason":""' "$derived_native_state_root/focused-verify-1.json" >/dev/null
grep -F 'bash scripts/test-native-claspc.sh' "$derived_native_state_root/focused-verify-1.json" >/dev/null
grep -F '$(scripts/resolve-claspc.sh) --json check examples/swarm-native/Main.clasp' "$derived_native_state_root/focused-verify-1.json" >/dev/null
if grep -F 'bash scripts/test-goal-manager-fast.sh' "$derived_native_state_root/focused-verify-1.json" >/dev/null; then
  printf 'native scenario focused diff unexpectedly selected goal-manager fast test\n' >&2
  exit 1
fi
if grep -F 'bash scripts/verify-fast.sh' "$derived_native_state_root/focused-verify-1.json" >/dev/null; then
  printf 'native scenario focused diff unexpectedly selected verify-fast\n' >&2
  exit 1
fi

fi

derived_goal_helper_state_root="$test_root_abs/loop-derived-goal-helper-focused-state"
derived_goal_helper_workspace_root="$fixture_project/.clasp-task-workspaces/derived-goal-helper-focused-task"
derived_goal_helper_baseline_root="$fixture_project/.clasp-task-baselines/derived-goal-helper-focused-task"
mkdir -p \
  "$derived_goal_helper_state_root" \
  "$derived_goal_helper_workspace_root/scripts" \
  "$derived_goal_helper_baseline_root/scripts"
printf 'base goal manager helper\n' >"$derived_goal_helper_baseline_root/scripts/ensure-goal-manager-binary.sh"
cp -a "$derived_goal_helper_baseline_root/." "$derived_goal_helper_workspace_root/"
printf 'changed goal manager helper\n' >"$derived_goal_helper_workspace_root/scripts/ensure-goal-manager-binary.sh"
cat >"$derived_goal_helper_state_root/state.json" <<'JSON'
{"attempt":1,"phase":"verifier-step-ready","verdict":"pending","completed":false,"builderRuns":1,"verifierRuns":1,"healthy":true,"needsAttention":false,"attentionReason":"","final":false}
JSON
cat >"$derived_goal_helper_state_root/builder-1.json" <<'JSON'
{"summary":"builder changed GoalManager binary helper","files_touched":["scripts/ensure-goal-manager-binary.sh"],"tests_run":[],"residual_risks":[],"feedback":{"summary":"derive GoalManager helper checks","ergonomics":[],"follow_ups":[],"warnings":[]}}
JSON
printf 'ready\n' >"$derived_goal_helper_state_root/baseline.ready"

if case_enabled goal-helper-routing; then
derived_goal_helper_output="$(
  env -u CLASP_LOOP_FOCUSED_VERIFY_COMMANDS_JSON \
  CLASP_LOOP_CODEX_BIN_JSON="\"$fake_codex_bin\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$derived_goal_helper_workspace_root\"" \
  CLASP_LOOP_BASELINE_WORKSPACE_JSON="\"$derived_goal_helper_baseline_root\"" \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='1' \
  CLASP_TEST_EXPECT_DERIVED_GOAL_MANAGER_HELPER_COMMANDS='1' \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$derived_goal_helper_state_root"
)"

printf '%s\n' "$derived_goal_helper_output" | grep -Fx 'pass:1' >/dev/null
test -f "$derived_goal_helper_state_root/focused-verify-1.json"
grep -F '"source":"diff-derived"' "$derived_goal_helper_state_root/focused-verify-1.json" >/dev/null
grep -F 'control_plane' "$derived_goal_helper_state_root/focused-verify-1.json" >/dev/null
grep -F '"fallbackReason":""' "$derived_goal_helper_state_root/focused-verify-1.json" >/dev/null
grep -F 'bash scripts/test-goal-manager-fast.sh' "$derived_goal_helper_state_root/focused-verify-1.json" >/dev/null
grep -F '$(scripts/resolve-claspc.sh) --json check examples/swarm-native/GoalManager.clasp' "$derived_goal_helper_state_root/focused-verify-1.json" >/dev/null
if grep -F 'unknown_path' "$derived_goal_helper_state_root/focused-verify-1.json" >/dev/null; then
  printf 'GoalManager helper focused diff was misclassified as unknown\n' >&2
  exit 1
fi
if grep -F 'bash scripts/verify-fast.sh' "$derived_goal_helper_state_root/focused-verify-1.json" >/dev/null; then
  printf 'GoalManager helper focused diff unexpectedly selected verify-fast\n' >&2
  exit 1
fi

fi

derived_speed_state_root="$test_root_abs/loop-derived-speed-focused-state"
derived_speed_workspace_root="$fixture_project/.clasp-task-workspaces/derived-speed-focused-task"
derived_speed_baseline_root="$fixture_project/.clasp-task-baselines/derived-speed-focused-task"
mkdir -p \
  "$derived_speed_state_root" \
  "$derived_speed_workspace_root/scripts" \
  "$derived_speed_baseline_root/scripts"
printf 'base speed guard\n' >"$derived_speed_baseline_root/scripts/measure-native-incremental.sh"
cp -a "$derived_speed_baseline_root/." "$derived_speed_workspace_root/"
printf 'changed speed guard\n' >"$derived_speed_workspace_root/scripts/measure-native-incremental.sh"
cat >"$derived_speed_state_root/state.json" <<'JSON'
{"attempt":1,"phase":"verifier-step-ready","verdict":"pending","completed":false,"builderRuns":1,"verifierRuns":1,"healthy":true,"needsAttention":false,"attentionReason":"","final":false}
JSON
cat >"$derived_speed_state_root/builder-1.json" <<'JSON'
{"summary":"builder changed native incremental measurement","files_touched":["scripts/measure-native-incremental.sh"],"tests_run":[],"residual_risks":[],"feedback":{"summary":"derive compiler speed checks","ergonomics":[],"follow_ups":[],"warnings":[]}}
JSON
printf 'ready\n' >"$derived_speed_state_root/baseline.ready"

if case_enabled speed-routing; then
derived_speed_output="$(
  env -u CLASP_LOOP_FOCUSED_VERIFY_COMMANDS_JSON \
  CLASP_LOOP_CODEX_BIN_JSON="\"$fake_codex_bin\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$derived_speed_workspace_root\"" \
  CLASP_LOOP_BASELINE_WORKSPACE_JSON="\"$derived_speed_baseline_root\"" \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='1' \
  CLASP_TEST_EXPECT_DERIVED_SPEED_COMMANDS='1' \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$derived_speed_state_root"
)"

printf '%s\n' "$derived_speed_output" | grep -Fx 'pass:1' >/dev/null
test -f "$derived_speed_state_root/focused-verify-1.json"
grep -F '"source":"diff-derived"' "$derived_speed_state_root/focused-verify-1.json" >/dev/null
grep -F 'compiler_speed' "$derived_speed_state_root/focused-verify-1.json" >/dev/null
grep -F '"fallbackReason":""' "$derived_speed_state_root/focused-verify-1.json" >/dev/null
grep -F 'bash scripts/test-native-incremental-guard.sh' "$derived_speed_state_root/focused-verify-1.json" >/dev/null
grep -F 'node --check scripts/native-incremental-guard.mjs' "$derived_speed_state_root/focused-verify-1.json" >/dev/null
if grep -F 'bash scripts/verify-fast.sh' "$derived_speed_state_root/focused-verify-1.json" >/dev/null; then
  printf 'compiler speed focused diff unexpectedly selected verify-fast\n' >&2
  exit 1
fi

fi

derived_verify_state_root="$test_root_abs/loop-derived-verify-focused-state"
derived_verify_workspace_root="$fixture_project/.clasp-task-workspaces/derived-verify-focused-task"
derived_verify_baseline_root="$fixture_project/.clasp-task-baselines/derived-verify-focused-task"
mkdir -p \
  "$derived_verify_state_root" \
  "$derived_verify_workspace_root/src/scripts" \
  "$derived_verify_baseline_root/src/scripts"
printf 'base verifier harness\n' >"$derived_verify_baseline_root/src/scripts/verify.sh"
cp -a "$derived_verify_baseline_root/." "$derived_verify_workspace_root/"
printf 'changed verifier harness\n' >"$derived_verify_workspace_root/src/scripts/verify.sh"
cat >"$derived_verify_state_root/state.json" <<'JSON'
{"attempt":1,"phase":"verifier-step-ready","verdict":"pending","completed":false,"builderRuns":1,"verifierRuns":1,"healthy":true,"needsAttention":false,"attentionReason":"","final":false}
JSON
cat >"$derived_verify_state_root/builder-1.json" <<'JSON'
{"summary":"builder changed selfhost verifier harness","files_touched":["src/scripts/verify.sh"],"tests_run":[],"residual_risks":[],"feedback":{"summary":"derive verifier harness checks","ergonomics":[],"follow_ups":[],"warnings":[]}}
JSON
printf 'ready\n' >"$derived_verify_state_root/baseline.ready"

if case_enabled verify-routing; then
derived_verify_output="$(
  env -u CLASP_LOOP_FOCUSED_VERIFY_COMMANDS_JSON \
  CLASP_LOOP_CODEX_BIN_JSON="\"$fake_codex_bin\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$derived_verify_workspace_root\"" \
  CLASP_LOOP_BASELINE_WORKSPACE_JSON="\"$derived_verify_baseline_root\"" \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='1' \
  CLASP_TEST_EXPECT_DERIVED_VERIFY_HARNESS_COMMANDS='1' \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$derived_verify_state_root"
)"

printf '%s\n' "$derived_verify_output" | grep -Fx 'pass:1' >/dev/null
test -f "$derived_verify_state_root/focused-verify-1.json"
grep -F '"source":"diff-derived"' "$derived_verify_state_root/focused-verify-1.json" >/dev/null
grep -F 'verification_harness' "$derived_verify_state_root/focused-verify-1.json" >/dev/null
grep -F '"fallbackReason":""' "$derived_verify_state_root/focused-verify-1.json" >/dev/null
grep -F 'bash scripts/test-verify-all.sh' "$derived_verify_state_root/focused-verify-1.json" >/dev/null
grep -F 'bash scripts/test-swarm-ready-gate.sh' "$derived_verify_state_root/focused-verify-1.json" >/dev/null
if grep -F 'compiler_runtime_broad' "$derived_verify_state_root/focused-verify-1.json" >/dev/null; then
  printf 'verifier harness focused diff was misclassified as compiler runtime broad\n' >&2
  exit 1
fi
if grep -F 'unknown_path' "$derived_verify_state_root/focused-verify-1.json" >/dev/null; then
  printf 'verifier harness focused diff was misclassified as unknown\n' >&2
  exit 1
fi
if grep -F 'bash scripts/verify-fast.sh' "$derived_verify_state_root/focused-verify-1.json" >/dev/null; then
  printf 'verifier harness focused diff unexpectedly selected verify-fast\n' >&2
  exit 1
fi

fi

unknown_state_root="$test_root_abs/loop-unknown-focused-state"
unknown_workspace_root="$fixture_project/.clasp-task-workspaces/unknown-focused-task"
unknown_baseline_root="$fixture_project/.clasp-task-baselines/unknown-focused-task"
mkdir -p "$unknown_state_root" "$unknown_workspace_root" "$unknown_baseline_root"
printf 'base readme\n' >"$unknown_baseline_root/README.md"
cp -a "$unknown_baseline_root/." "$unknown_workspace_root/"
printf 'changed readme\n' >"$unknown_workspace_root/README.md"
cat >"$unknown_state_root/state.json" <<'JSON'
{"attempt":1,"phase":"verifier-step-ready","verdict":"pending","completed":false,"builderRuns":1,"verifierRuns":1,"healthy":true,"needsAttention":false,"attentionReason":"","final":false}
JSON
cat >"$unknown_state_root/builder-1.json" <<'JSON'
{"summary":"builder changed an unknown surface","files_touched":["README.md"],"tests_run":[],"residual_risks":[],"feedback":{"summary":"empty manager commands must derive verify-fast","ergonomics":[],"follow_ups":[],"warnings":[]}}
JSON
printf 'ready\n' >"$unknown_state_root/baseline.ready"

if case_enabled unknown-routing; then
unknown_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$fake_codex_bin\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$unknown_workspace_root\"" \
  CLASP_LOOP_BASELINE_WORKSPACE_JSON="\"$unknown_baseline_root\"" \
  CLASP_LOOP_FOCUSED_VERIFY_COMMANDS_JSON='""' \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='1' \
  CLASP_TEST_EXPECT_UNKNOWN_VERIFY_FAST='1' \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$unknown_state_root"
)"

printf '%s\n' "$unknown_output" | grep -Fx 'pass:1' >/dev/null
test -f "$unknown_state_root/focused-verify-1.json"
grep -F '"source":"diff-derived"' "$unknown_state_root/focused-verify-1.json" >/dev/null
grep -F 'unknown_path' "$unknown_state_root/focused-verify-1.json" >/dev/null
grep -F 'diff included unknown paths; selected conservative verify-fast' "$unknown_state_root/focused-verify-1.json" >/dev/null
grep -F 'one or more changed paths did not match a known narrow surface; focused selection falls back to verify-fast' "$unknown_state_root/focused-verify-1.json" >/dev/null
grep -F 'bash scripts/verify-fast.sh' "$unknown_state_root/focused-verify-1.json" >/dev/null
if grep -F 'bash scripts/verify-all.sh' "$unknown_state_root/focused-verify-1.json" >/dev/null; then
  printf 'unknown focused diff selected verify-all instead of verify-fast\n' >&2
  exit 1
fi

fi

missing_state_root="$test_root_abs/loop-missing-baseline-state"
missing_workspace_root="$fixture_project/.clasp-task-workspaces/missing-baseline-task"
missing_baseline_root="$fixture_project/.clasp-task-baselines/missing-baseline-task"
mkdir -p "$missing_state_root" "$missing_workspace_root"
printf 'builder-change\n' >"$missing_workspace_root/workspace.txt"
cat >"$missing_state_root/state.json" <<'JSON'
{"attempt":1,"phase":"verifier-step-ready","verdict":"pending","completed":false,"builderRuns":1,"verifierRuns":1,"healthy":true,"needsAttention":false,"attentionReason":"","final":false}
JSON
cat >"$missing_state_root/builder-1.json" <<'JSON'
{"summary":"builder completed before baseline disappeared","files_touched":["workspace.txt"],"tests_run":[],"residual_risks":[],"feedback":{"summary":"missing baseline must fail closed","ergonomics":[],"follow_ups":[],"warnings":[]}}
JSON
printf 'ready\n' >"$missing_state_root/baseline.ready"

if case_enabled missing-baseline; then
missing_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$fake_codex_bin\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$missing_workspace_root\"" \
  CLASP_LOOP_BASELINE_WORKSPACE_JSON="\"$missing_baseline_root\"" \
  CLASP_LOOP_FOCUSED_VERIFY_COMMANDS_JSON='"runtime/target/debug/claspc --json check examples/feedback-loop/Main.clasp; bash scripts/test-swarm-ready-gate.sh"' \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='1' \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$missing_state_root"
)"

printf '%s\n' "$missing_output" | grep -F 'baseline-error:provided baseline workspace is missing; refusing to recreate it from a workspace that may contain builder changes' >/dev/null
test ! -e "$missing_baseline_root"
test ! -e "$missing_state_root/verifier-1.json"
fi
