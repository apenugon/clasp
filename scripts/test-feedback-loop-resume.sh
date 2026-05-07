#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${CLASP_TEST_TMPDIR:-${TMPDIR:-/tmp}}"
mkdir -p "$tmp_root"
test_root="$(mktemp -d "$tmp_root/test-feedback-loop-resume.XXXXXX")"
test_root_abs="$(cd "$test_root" && pwd -P)"
export XDG_CACHE_HOME="$test_root_abs/xdg-cache"

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
      prompt="$1"
      shift
      ;;
  esac
done

if [[ -z "$report_path" ]]; then
  printf 'missing report path\n' >&2
  exit 2
fi

state_root="$(dirname "$report_path")"
mkdir -p "$state_root"

if [[ "$prompt" == *"builder subagent"* ]]; then
  printf 'builder was re-run during verifier resume\n' >"$state_root/builder-reran.marker"
  exit 65
fi

if [[ "$prompt" != *"verifier subagent"* ]]; then
  printf 'unexpected fake codex prompt\n' >&2
  exit 66
fi

if [[ ! -f "$state_root/changes-1.diff" ]]; then
  printf 'missing refreshed baseline diff before verifier launch\n' >&2
  exit 67
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

resume_output="$(
  CLASP_LOOP_CODEX_BIN_JSON="\"$fake_codex_bin\"" \
  CLASP_LOOP_TASK_FILE_JSON="\"$task_file\"" \
  CLASP_LOOP_WORKSPACE_JSON="\"$workspace_root\"" \
  CLASP_LOOP_BASELINE_WORKSPACE_JSON="\"$baseline_root\"" \
  CLASP_LOOP_FOCUSED_VERIFY_COMMANDS_JSON='"runtime/target/debug/claspc --json check examples/feedback-loop/Main.clasp; bash scripts/test-swarm-ready-gate.sh"' \
  CLASP_LOOP_MAX_ATTEMPTS_JSON='1' \
  "$claspc_bin" run "$project_root/examples/feedback-loop/Main.clasp" -- "$state_root"
)"

printf '%s\n' "$resume_output" | grep -Fx 'pass:1' >/dev/null
test -f "$state_root/verifier-1.json"
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
