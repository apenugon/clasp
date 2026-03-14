#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runs_root=""
markers_root=""
repo_root=""
lane_root=""
completed_root=""
blocked_root=""
global_completed_root=""
spawn_root=""
spawn_path_root=""
invalid_lane_root=""
autopilot_test_root=""
autopilot_test_root_2=""
lane_merge_test_root=""
lane_cleanup_test_root=""
prompt_test_root=""
prompt_test_root_2=""
status_wave_name=""
status_lane_root_1=""
status_lane_root_2=""
status_runtime_root_1=""
status_runtime_root_2=""
status_text_output=""
status_json_output=""
status_live_pid=""

cleanup() {
  if [[ -n "${status_live_pid:-}" ]]; then
    kill "${status_live_pid}" >/dev/null 2>&1 || true
  fi
  rm -rf "${runs_root:-}" "${markers_root:-}" "${repo_root:-}" "${lane_root:-}" "${completed_root:-}" "${blocked_root:-}" "${global_completed_root:-}" "${spawn_root:-}" "${spawn_path_root:-}" "${invalid_lane_root:-}" "${autopilot_test_root:-}" "${autopilot_test_root_2:-}" "${lane_merge_test_root:-}" "${lane_cleanup_test_root:-}" "${prompt_test_root:-}" "${prompt_test_root_2:-}" "${status_lane_root_1:-}" "${status_lane_root_2:-}" "${status_runtime_root_1:-}" "${status_runtime_root_2:-}"
  rm -f "${status_text_output:-}" "${status_json_output:-}"
}

trap cleanup EXIT

write_task_manifest() {
  local task_file="$1"
  local title="$2"
  local dependency="${3:-None}"

  cat > "$task_file" <<EOF
# $title

## Goal

Exercise autopilot queue behavior for $title.

## Why

Regression coverage for the swarm control plane should stay local and deterministic.

## Scope

- Keep the scenario minimal

## Likely Files

- \`scripts/test-swarm-control.sh\`

## Dependencies

- $dependency

## Acceptance

- done

## Verification

\`\`\`sh
bash scripts/verify-all.sh
\`\`\`
EOF
}

make_prompt_test_project() {
  local target_root="$1"
  local project_dir="$target_root/repo"

  mkdir -p "$project_dir/scripts" "$project_dir/agents/schemas" "$project_dir/tools"
  cp \
    "$project_root/scripts/clasp-builder.sh" \
    "$project_root/scripts/clasp-codex-home.sh" \
    "$project_root/scripts/clasp-swarm-common.sh" \
    "$project_root/scripts/clasp-verifier.sh" \
    "$project_dir/scripts/"
  cp \
    "$project_root/agents/schemas/builder-report.schema.json" \
    "$project_root/agents/schemas/verifier-report.schema.json" \
    "$project_dir/agents/schemas/"

  cat > "$project_dir/tools/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

cat > "${CLASP_TEST_PROMPT_CAPTURE:?}"

case "${CLASP_TEST_CODEX_MODE:-builder}" in
  builder)
    cat > "$output_file" <<'JSON'
{
  "summary": "stub builder report",
  "files_touched": [],
  "tests_run": [],
  "residual_risks": []
}
JSON
    ;;
  verifier)
    cat > "$output_file" <<'JSON'
{
  "verdict": "pass",
  "summary": "stub verifier report",
  "findings": [],
  "tests_run": [],
  "follow_up": []
}
JSON
    ;;
  *)
    echo "unknown CLASP_TEST_CODEX_MODE" >&2
    exit 1
    ;;
esac
EOF

  chmod +x "$project_dir/tools/codex"
  printf '%s\n' "$project_dir"
}

make_autopilot_test_project() {
  local target_root="$1"
  local scenario="$2"
  local project_dir="$target_root/repo"

  mkdir -p "$project_dir/scripts" "$project_dir/tools" "$project_dir/agents/tasks" "$project_dir/verifier-state"
  cp "$project_root/scripts/clasp-autopilot.sh" "$project_dir/scripts/clasp-autopilot.sh"
  printf '%s\n' "$scenario" > "$project_dir/scenario"

  cat > "$project_dir/scripts/clasp-builder.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

task_file="$1"
workspace="$2"
report_json="$3"
log_jsonl="$4"
task_id="$(basename "$task_file" .md)"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

printf 'builder:%s\n' "$task_id" >> "$project_root/test-events.log"
if [[ "$task_id" == *"--workaround" ]]; then
  printf 'fixed\n' > "$workspace/.workaround-fixed"
fi

cat > "$report_json" <<JSON
{
  "summary": "builder finished for $task_id",
  "files_touched": [],
  "tests_run": [],
  "residual_risks": []
}
JSON

: > "$log_jsonl"
EOF

  cat > "$project_dir/scripts/clasp-verifier.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

task_file="$1"
workspace="$2"
baseline_workspace="$3"
report_json="$4"
log_jsonl="$5"
task_id="$(basename "$task_file" .md)"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_dir="$project_root/verifier-state"
scenario="$(< "$project_root/scenario")"
attempt_file="$state_dir/$task_id.attempts"
attempt=0

if [[ -f "$attempt_file" ]]; then
  attempt="$(< "$attempt_file")"
fi
attempt=$((attempt + 1))
printf '%s\n' "$attempt" > "$attempt_file"

verdict="pass"
summary="verified"
findings_json='[]'
follow_up_json='[]'

case "$task_id" in
  AA-001-parent)
    if [[ ! -f "$workspace/.workaround-fixed" ]]; then
      verdict="fail"
      summary="parent task still needs a workaround"
      findings_json='["Missing workaround marker in the builder workspace."]'
      follow_up_json='["Generate and land the workaround task before retrying the parent."]'
    fi
    ;;
  AA-001-parent--workaround)
    if [[ "$scenario" == "fail-workaround" ]]; then
      verdict="fail"
      summary="workaround task remains blocked"
      findings_json='["The generated workaround intentionally fails in this scenario."]'
      follow_up_json='["Leave the workaround blocked and continue later ready tasks."]'
    fi
    ;;
esac

printf 'verifier:%s:%s\n' "$task_id" "$verdict" >> "$project_root/test-events.log"

cat > "$report_json" <<JSON
{
  "verdict": "$verdict",
  "summary": "$summary",
  "findings": $findings_json,
  "tests_run": [
    "stub verifier for $task_id"
  ],
  "follow_up": $follow_up_json
}
JSON

: > "$log_jsonl"
EOF

  cat > "$project_dir/tools/flock" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF

  chmod +x \
    "$project_dir/scripts/clasp-autopilot.sh" \
    "$project_dir/scripts/clasp-builder.sh" \
    "$project_dir/scripts/clasp-verifier.sh" \
    "$project_dir/tools/flock"

  printf '%s\n' "$project_dir"
}

make_lane_merge_test_project() {
  local target_root="$1"
  local project_dir="$target_root/repo"

  mkdir -p \
    "$project_dir/scripts" \
    "$project_dir/tools" \
    "$project_dir/agents/swarm/test-wave/01-merge-gate"

  cp \
    "$project_root/scripts/clasp-swarm-common.sh" \
    "$project_root/scripts/clasp-swarm-lane.sh" \
    "$project_root/scripts/clasp-swarm-validate-task.mjs" \
    "$project_dir/scripts/"
  cp "$project_root/agents/swarm/task.schema.json" "$project_dir/agents/swarm/task.schema.json"

  cat > "$project_dir/scripts/clasp-builder.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

task_file="$1"
workspace="$2"
report_json="$3"
log_jsonl="$4"
task_id="$(basename "$task_file" .md)"

printf 'builder-change\n' > "$workspace/feature.txt"

cat > "$report_json" <<JSON
{
  "summary": "builder finished for $task_id",
  "files_touched": [
    "feature.txt"
  ],
  "tests_run": [],
  "residual_risks": []
}
JSON

: > "$log_jsonl"
EOF

  cat > "$project_dir/scripts/clasp-verifier.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

task_file="$1"
workspace="$2"
baseline_workspace="$3"
report_json="$4"
log_jsonl="$5"
task_id="$(basename "$task_file" .md)"

if [[ "$(cat "$baseline_workspace/feature.txt")" != "base\n" && "$(cat "$baseline_workspace/feature.txt")" != "base" ]]; then
  echo "unexpected baseline contents" >&2
  exit 1
fi

printf 'verified-by-verifier\n' > "$workspace/verifier-only.txt"
rm -f "$workspace/remove-me.txt"

cat > "$report_json" <<JSON
{
  "verdict": "pass",
  "summary": "verified $task_id",
  "findings": [],
  "tests_run": [
    "verifier workspace delta scenario"
  ],
  "follow_up": []
}
JSON

: > "$log_jsonl"
EOF

  cat > "$project_dir/scripts/verify-all.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ -f feature.txt ]]
[[ "$(< feature.txt)" == "builder-change" ]]
[[ -f verifier-only.txt ]]
[[ "$(< verifier-only.txt)" == "verified-by-verifier" ]]
[[ ! -e remove-me.txt ]]
EOF

  chmod +x \
    "$project_dir/scripts/clasp-builder.sh" \
    "$project_dir/scripts/clasp-swarm-common.sh" \
    "$project_dir/scripts/clasp-swarm-lane.sh" \
    "$project_dir/scripts/clasp-swarm-validate-task.mjs" \
    "$project_dir/scripts/clasp-verifier.sh" \
    "$project_dir/scripts/verify-all.sh"

  cat > "$project_dir/agents/swarm/test-wave/01-merge-gate/SW-005-merge-copy.md" <<'EOF'
# SW-005 Merge copy

## Goal

Verify that the merge gate copies the verified workspace snapshot into the accepted snapshot.

## Why

Regression coverage for verifier-time workspace changes should stay end-to-end.

## Scope

- Exercise one lane task

## Likely Files

- `scripts/clasp-swarm-lane.sh`

## Dependencies

- None

## Acceptance

- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
EOF

  (
    cd "$project_dir"
    git init -b main >/dev/null
    git config user.name 'Swarm Test'
    git config user.email 'swarm-test@example.com'
    printf 'base\n' > feature.txt
    printf 'remove-this\n' > remove-me.txt
    git add .
    git commit -m 'base snapshot' >/dev/null
  )

  printf '%s\n' "$project_dir"
}

make_lane_cleanup_test_project() {
  local target_root="$1"
  local project_dir="$target_root/repo"

  mkdir -p \
    "$project_dir/scripts" \
    "$project_dir/agents/swarm/test-wave/01-cleanup"

  cp \
    "$project_root/scripts/clasp-swarm-common.sh" \
    "$project_root/scripts/clasp-swarm-lane.sh" \
    "$project_root/scripts/clasp-swarm-validate-task.mjs" \
    "$project_dir/scripts/"
  cp "$project_root/agents/swarm/task.schema.json" "$project_dir/agents/swarm/task.schema.json"

  cat > "$project_dir/scripts/clasp-builder.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

task_file="$1"
workspace="$2"
report_json="$3"
log_jsonl="$4"
task_id="$(basename "$task_file" .md)"

printf 'fresh-builder-change\n' > "$workspace/feature.txt"

cat > "$report_json" <<JSON
{
  "summary": "builder finished for $task_id",
  "files_touched": [
    "feature.txt"
  ],
  "tests_run": [],
  "residual_risks": []
}
JSON

: > "$log_jsonl"
EOF

  cat > "$project_dir/scripts/clasp-verifier.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

task_file="$1"
workspace="$2"
baseline_workspace="$3"
report_json="$4"
log_jsonl="$5"
task_id="$(basename "$task_file" .md)"

[[ "$(< "$baseline_workspace/feature.txt")" == "base" ]]

cat > "$report_json" <<JSON
{
  "verdict": "pass",
  "summary": "verified $task_id",
  "findings": [],
  "tests_run": [
    "stale run cleanup scenario"
  ],
  "follow_up": []
}
JSON

: > "$log_jsonl"
EOF

  cat > "$project_dir/scripts/verify-all.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ "$(< feature.txt)" == "fresh-builder-change" ]]
EOF

  chmod +x \
    "$project_dir/scripts/clasp-builder.sh" \
    "$project_dir/scripts/clasp-swarm-common.sh" \
    "$project_dir/scripts/clasp-swarm-lane.sh" \
    "$project_dir/scripts/clasp-swarm-validate-task.mjs" \
    "$project_dir/scripts/clasp-verifier.sh" \
    "$project_dir/scripts/verify-all.sh"

  cat > "$project_dir/agents/swarm/test-wave/01-cleanup/SW-006-cleanup.md" <<'EOF'
# SW-006 Cleanup

## Goal

Clean up stale run state before retrying the lane task.

## Why

Regression coverage for lane restart cleanup should stay end-to-end.

## Scope

- Exercise one stale run and one fresh retry

## Likely Files

- `scripts/clasp-swarm-lane.sh`

## Dependencies

- None

## Acceptance

- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
EOF

  (
    cd "$project_dir"
    git init -b main >/dev/null
    git config user.name 'Swarm Test'
    git config user.email 'swarm-test@example.com'
    printf 'base\n' > feature.txt
    git add .
    git commit -m 'base snapshot' >/dev/null
  )

  printf '%s\n' "$project_dir"
}

bash -n \
  "$project_root/scripts/clasp-builder.sh" \
  "$project_root/scripts/clasp-swarm-common.sh" \
  "$project_root/scripts/clasp-swarm-lane.sh" \
  "$project_root/scripts/clasp-swarm-start.sh" \
  "$project_root/scripts/clasp-swarm-status.sh" \
  "$project_root/scripts/clasp-swarm-stop.sh" \
  "$project_root/scripts/clasp-verifier.sh"

bash -lc "
  set -euo pipefail
  source '$project_root/scripts/clasp-swarm-common.sh'
  [[ \$(clasp_swarm_task_key 'SW-001-do-something.md') == 'SW-001' ]]
  [[ \$(clasp_swarm_task_key 'agents/swarm/full/02-core-language/LG-019-type-inference.md') == 'LG-019' ]]
  node '$project_root/scripts/clasp-swarm-validate-task.mjs' '$project_root/agents/swarm/full/01-swarm-infra/SW-001-replace-the-current-coarse-agents-tasks-backlog-with-a-granular-task-manifest-template-and-task-schema.md' >/dev/null
  [[ \$(node '$project_root/scripts/clasp-swarm-validate-task.mjs' --print-field taskId '$project_root/agents/swarm/full/01-swarm-infra/SW-001-replace-the-current-coarse-agents-tasks-backlog-with-a-granular-task-manifest-template-and-task-schema.md') == 'SW-001-replace-the-current-coarse-agents-tasks-backlog-with-a-granular-task-manifest-template-and-task-schema' ]]
  [[ \$(node '$project_root/scripts/clasp-swarm-validate-task.mjs' --print-field taskKey '$project_root/agents/swarm/full/01-swarm-infra/SW-001-replace-the-current-coarse-agents-tasks-backlog-with-a-granular-task-manifest-template-and-task-schema.md') == 'SW-001' ]]
  clasp_swarm_retry_limit_is_bounded '2'
  ! clasp_swarm_retry_limit_is_bounded '0'
  ! clasp_swarm_retry_limit_is_bounded '-1'
  ! clasp_swarm_retry_limit_is_bounded 'forever'
" >/dev/null

spawn_root="$(mktemp -d)"
spawn_path_root="$(mktemp -d)"
ln -s "$(command -v bash)" "$spawn_path_root/bash"
ln -s "$(command -v python3)" "$spawn_path_root/python3"
ln -s "$(command -v nohup)" "$spawn_path_root/nohup"
ln -s "$(command -v sleep)" "$spawn_path_root/sleep"

bash -lc "
  set -euo pipefail
  source '$project_root/scripts/clasp-swarm-common.sh'
  export PATH='$spawn_path_root'
  export CLASP_SWARM_SPAWN_OUTPUT='$spawn_root/output.txt'
  pid=\$(clasp_swarm_spawn_detached '$spawn_root/spawn.log' bash -lc 'printf detached > \"\$CLASP_SWARM_SPAWN_OUTPUT\"; sleep 1')
  [[ -n \"\$pid\" ]]

  deadline=\$((SECONDS + 5))
  while [[ ! -f '$spawn_root/output.txt' ]]; do
    if (( SECONDS >= deadline )); then
      echo 'timed out waiting for detached command output' >&2
      exit 1
    fi
    sleep 0.1
  done

  [[ \$(< '$spawn_root/output.txt') == 'detached' ]]
  kill \"\$pid\" >/dev/null 2>&1 || true
" >/dev/null

bash -lc "
  set -euo pipefail
  set +e
  (
    set -euo pipefail
    false
    printf 'unexpected\\n'
  ) >/dev/null 2>&1
  status=\$?
  set -e
  [[ \$status -ne 0 ]]
" >/dev/null

repo_root="$(mktemp -d)"

bash -lc "
  set -euo pipefail
  source '$project_root/scripts/clasp-swarm-common.sh'
  repo_root='$repo_root'
  git -C \"\$repo_root\" init -b main >/dev/null
  git -C \"\$repo_root\" config user.name 'Swarm Test'
  git -C \"\$repo_root\" config user.email 'swarm-test@example.com'
  printf 'base\n' > \"\$repo_root/file.txt\"
  git -C \"\$repo_root\" add file.txt
  git -C \"\$repo_root\" commit -m 'base' >/dev/null
  git -C \"\$repo_root\" branch agents/swarm-trunk

  printf 'main-only\n' >> \"\$repo_root/file.txt\"
  git -C \"\$repo_root\" commit -am 'main update' >/dev/null
  clasp_swarm_reconcile_main_and_trunk \"\$repo_root\" main agents/swarm-trunk >/dev/null
  [[ \$(git -C \"\$repo_root\" rev-parse main) == \$(git -C \"\$repo_root\" rev-parse agents/swarm-trunk) ]]

  git -C \"\$repo_root\" checkout agents/swarm-trunk >/dev/null 2>&1
  printf 'trunk-only\n' >> \"\$repo_root/file.txt\"
  git -C \"\$repo_root\" commit -am 'trunk update' >/dev/null
  git -C \"\$repo_root\" checkout main >/dev/null 2>&1
  clasp_swarm_reconcile_main_and_trunk \"\$repo_root\" main agents/swarm-trunk >/dev/null
  [[ \$(git -C \"\$repo_root\" rev-parse main) == \$(git -C \"\$repo_root\" rev-parse agents/swarm-trunk) ]]

  printf 'diverged-main\n' >> \"\$repo_root/file.txt\"
  git -C \"\$repo_root\" commit -am 'diverged main' >/dev/null
  git -C \"\$repo_root\" checkout agents/swarm-trunk >/dev/null 2>&1
  printf 'diverged-trunk\n' >> \"\$repo_root/file.txt\"
  git -C \"\$repo_root\" commit -am 'diverged trunk' >/dev/null
  git -C \"\$repo_root\" checkout main >/dev/null 2>&1
  ! clasp_swarm_reconcile_main_and_trunk \"\$repo_root\" main agents/swarm-trunk >/dev/null 2>&1
  [[ \$(git -C \"\$repo_root\" rev-parse --abbrev-ref HEAD) == 'main' ]]
" >/dev/null

runs_root="$(mktemp -d)"
mkdir -p \
  "$runs_root/20260311T200000Z-SW-001-first-attempt1" \
  "$runs_root/20260311T201500Z-SW-001-first-attempt2"

bash -lc "
  set -euo pipefail
  source '$project_root/scripts/clasp-swarm-common.sh'
  latest_run=\$(clasp_swarm_latest_task_run_dir '$runs_root' 'SW-001')
  [[ \$(basename \"\$latest_run\") == '20260311T201500Z-SW-001-first-attempt2' ]]
  [[ \$(clasp_swarm_task_run_attempt \"\$latest_run\") == '2' ]]
" >/dev/null

lanes=()
while IFS= read -r lane; do
  [[ -n "$lane" ]] || continue
  lanes+=("$lane")
done < <(bash "$project_root/scripts/clasp-swarm-start.sh" --list-lanes wave1)

if [[ "${#lanes[@]}" -lt 1 ]]; then
  echo "expected at least one wave1 lane" >&2
  exit 1
fi

for lane_dir in "${lanes[@]}"; do
  bash "$project_root/scripts/clasp-swarm-lane.sh" --list-tasks "$lane_dir" >/dev/null
done

bash "$project_root/scripts/clasp-swarm-status.sh" wave1 >/dev/null

default_lanes=()
while IFS= read -r lane; do
  [[ -n "$lane" ]] || continue
  default_lanes+=("$lane")
done < <(bash "$project_root/scripts/clasp-swarm-start.sh" --list-lanes)

if [[ "${#default_lanes[@]}" -lt 1 ]]; then
  echo "expected at least one default-wave lane" >&2
  exit 1
fi

for lane_dir in "${default_lanes[@]}"; do
  bash "$project_root/scripts/clasp-swarm-lane.sh" --list-tasks "$lane_dir" >/dev/null
done

bash "$project_root/scripts/clasp-swarm-status.sh" >/dev/null

status_wave_name="status-test-$$"
status_lane_root_1="$project_root/agents/swarm/$status_wave_name/01-active"
status_lane_root_2="$project_root/agents/swarm/$status_wave_name/02-idle"
status_runtime_root_1="$project_root/.clasp-swarm/$status_wave_name/01-active"
status_runtime_root_2="$project_root/.clasp-swarm/$status_wave_name/02-idle"
status_text_output="$(mktemp)"
status_json_output="$(mktemp)"

mkdir -p \
  "$status_runtime_root_1" \
  "$status_runtime_root_2" \
  "$status_lane_root_1" \
  "$status_lane_root_2" \
  "$status_runtime_root_1/completed" \
  "$status_runtime_root_1/blocked" \
  "$status_runtime_root_1/runs/20260314T120000Z-AA-100-sample-attempt1" \
  "$status_runtime_root_1/runs/20260314T121500Z-AA-100-sample-attempt2" \
  "$status_runtime_root_2/completed" \
  "$status_runtime_root_2/blocked" \
  "$status_runtime_root_2/runs/20260314T122000Z-BB-200-sample-attempt1"

printf '%s\n' "AA-100-sample" > "$status_runtime_root_1/current-task.txt"
printf '%s\n' "done" > "$status_runtime_root_1/completed/AA-001"
printf '%s\n' "done" > "$status_runtime_root_1/completed/AA-002"
printf '%s\n' '{}' > "$status_runtime_root_1/blocked/AA-003.json"
cat > "$status_runtime_root_1/runs/20260314T120000Z-AA-100-sample-attempt1/verifier-report.json" <<'EOF'
{
  "verdict": "fail",
  "summary": "older failed attempt",
  "findings": [],
  "tests_run": [],
  "follow_up": []
}
EOF
cat > "$status_runtime_root_1/runs/20260314T121500Z-AA-100-sample-attempt2/verifier-report.json" <<'EOF'
{
  "verdict": "pass",
  "summary": "latest verifier summary",
  "findings": [],
  "tests_run": [],
  "follow_up": []
}
EOF
cat > "$status_runtime_root_1/lane.log" <<'EOF'
line 1
line 2
line 3
line 4
line 5
line 6
EOF

printf '%s\n' "done" > "$status_runtime_root_2/completed/BB-001"
cat > "$status_runtime_root_2/runs/20260314T122000Z-BB-200-sample-attempt1/builder-report.json" <<'EOF'
{
  "summary": "builder summary only",
  "files_touched": [],
  "tests_run": [],
  "residual_risks": []
}
EOF
cat > "$status_runtime_root_2/lane.log" <<'EOF'
idle line 1
idle line 2
EOF

sleep 30 >/dev/null 2>&1 &
status_live_pid="$!"
printf '%s\n' "$status_live_pid" > "$status_runtime_root_1/pid"
kill "$status_live_pid" >/dev/null 2>&1 || true
wait "$status_live_pid" 2>/dev/null || true

sleep 30 >/dev/null 2>&1 &
status_live_pid="$!"
printf '%s\n' "$status_live_pid" > "$status_runtime_root_2/pid"

bash "$project_root/scripts/clasp-swarm-status.sh" "$status_wave_name" > "$status_text_output"
bash "$project_root/scripts/clasp-swarm-status.sh" --json "$status_wave_name" > "$status_json_output"

bash -lc "
  set -euo pipefail
  text=\$(cat '$status_text_output')
  [[ \"\$text\" == *'wave: $status_wave_name'* ]]
  [[ \"\$text\" == *'summary: lanes=2 running=1 stopped=1 completed=3 blocked=1'* ]]
  [[ \"\$text\" == *'lane: 01-active'* ]]
  [[ \"\$text\" == *'stale pid: '* ]]
  [[ \"\$text\" == *'current task: AA-100-sample'* ]]
  [[ \"\$text\" == *'latest run: 20260314T121500Z-AA-100-sample-attempt2'* ]]
  [[ \"\$text\" == *'run status: pass'* ]]
  [[ \"\$text\" == *'run summary: latest verifier summary'* ]]
  [[ \"\$text\" == *'lane: 02-idle'* ]]
  [[ \"\$text\" == *'pid: $status_live_pid'* ]]
  [[ \"\$text\" == *'run status: builder-complete'* ]]
  [[ \"\$text\" == *'run summary: builder summary only'* ]]
  [[ \"\$text\" == *'line 6'* ]]
  [[ \"\$text\" == *'idle line 2'* ]]
  node - <<'EOF' '$status_json_output' '$status_wave_name' '$status_live_pid'
const fs = require('fs');
const [jsonPath, expectedWave, livePid] = process.argv.slice(2);
const payload = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
if (payload.wave !== expectedWave) {
  throw new Error(\`unexpected wave: \${payload.wave}\`);
}
if (payload.summary.laneCount !== 2 || payload.summary.runningCount !== 1 || payload.summary.stoppedCount !== 1) {
  throw new Error('unexpected lane summary counts');
}
if (payload.summary.completedCount !== 3 || payload.summary.blockedCount !== 1) {
  throw new Error('unexpected completion summary counts');
}
const active = payload.lanes.find((lane) => lane.lane === '01-active');
const idle = payload.lanes.find((lane) => lane.lane === '02-idle');
if (!active || !idle) {
  throw new Error('expected both lanes in JSON output');
}
if (active.status !== 'stopped' || active.stalePid === null || active.currentTask !== 'AA-100-sample') {
  throw new Error('unexpected active-lane JSON state');
}
if (active.latestRun?.status !== 'pass' || active.latestRun?.summary !== 'latest verifier summary') {
  throw new Error('unexpected active-lane run summary');
}
if (idle.status !== 'running' || String(idle.pid) !== livePid) {
  throw new Error('unexpected idle-lane pid state');
}
if (idle.latestRun?.status !== 'builder-complete' || idle.latestRun?.summary !== 'builder summary only') {
  throw new Error('unexpected idle-lane run summary');
}
if (!Array.isArray(active.recentLogLines) || active.recentLogLines.at(-1) !== 'line 6') {
  throw new Error('unexpected active-lane log tail');
}
if (!Array.isArray(idle.recentLogLines) || idle.recentLogLines.at(-1) !== 'idle line 2') {
  throw new Error('unexpected idle-lane log tail');
}
EOF
" >/dev/null

kill "$status_live_pid" >/dev/null 2>&1 || true
wait "$status_live_pid" 2>/dev/null || true
status_live_pid=""

markers_root="$(mktemp -d)"
printf '%s\n' "legacy" > "$markers_root/SW-001-some-slug"

bash -lc "
  set -euo pipefail
  source '$project_root/scripts/clasp-swarm-common.sh'
  clasp_swarm_completion_marker_exists '$markers_root' 'SW-001'
  clasp_swarm_normalize_completion_dir '$markers_root'
  clasp_swarm_completion_marker_exists '$markers_root' 'SW-001'
  [[ -f '$markers_root/SW-001' ]]
  [[ ! -f '$markers_root/SW-001-some-slug' ]]
" >/dev/null

bash -lc "
  set -euo pipefail
  source '$project_root/scripts/clasp-swarm-common.sh'
  project_root='$project_root'
  feedback_dir=\$(clasp_swarm_feedback_dir \"\$project_root\")
  feedback_path=\$(clasp_swarm_feedback_path \"\$project_root\" 'TY-003')
  [[ \"\$feedback_dir\" == '$project_root/agents/feedback' ]]
  [[ \"\$feedback_path\" == '$project_root/agents/feedback/TY-003.json' ]]
  ! clasp_swarm_feedback_required \"\$project_root\" 'SH-014'
  mkdir -p \"\$project_root/.clasp-swarm/completed\"
  printf '%s\t%s\n' '2026-03-13T00:00:00Z' 'deadbeef' > \"\$project_root/.clasp-swarm/completed/SH-014\"
  clasp_swarm_feedback_required \"\$project_root\" 'SH-014'
  rm -f \"\$project_root/.clasp-swarm/completed/SH-014\"
" >/dev/null

lane_root="$(mktemp -d)"
completed_root="$(mktemp -d)"
blocked_root="$(mktemp -d)"
global_completed_root="$(mktemp -d)"

cat > "$lane_root/ZZ-001-late-consumer.md" <<'EOF'
# ZZ-001 Late consumer

## Goal

Run after the prerequisite task.

## Why

This task proves dependency ordering.

## Scope

- Wait for ZZ-003

## Likely Files

- `src/late-consumer`

## Dependencies

- `ZZ-003`

## Acceptance

- done

## Verification

```sh
bash scripts/verify-all.sh
```
EOF

cat > "$lane_root/ZZ-002-ready-now.md" <<'EOF'
# ZZ-002 Ready now

## Goal

Run immediately when no dependencies block it.

## Why

This task proves the lane can pick a ready task first.

## Scope

- Run before dependent tasks

## Likely Files

- `src/ready-now`

## Dependencies

- None

## Acceptance

- done

## Verification

```sh
bash scripts/verify-all.sh
```
EOF

cat > "$lane_root/ZZ-003-prerequisite.md" <<'EOF'
# ZZ-003 Prerequisite

## Goal

Unlock the dependent task.

## Why

This task proves prerequisites are selected before dependents.

## Scope

- Complete before ZZ-001

## Likely Files

- `src/prerequisite`

## Dependencies

- None

## Acceptance

- done

## Verification

```sh
bash scripts/verify-all.sh
```
EOF

bash -lc "
  set -euo pipefail
  source '$project_root/scripts/clasp-swarm-common.sh'
  next=\$(clasp_swarm_select_next_ready_task '$lane_root' '$completed_root' '$global_completed_root' '$blocked_root')
  [[ \$(basename \"\$next\") == 'ZZ-002-ready-now.md' ]]

  printf '%s\t%s\n' '2026-03-13T00:00:00Z' 'deadbeef' > '$global_completed_root/ZZ-002'
  next=\$(clasp_swarm_select_next_ready_task '$lane_root' '$completed_root' '$global_completed_root' '$blocked_root')
  [[ \$(basename \"\$next\") == 'ZZ-003-prerequisite.md' ]]

  printf '%s\t%s\n' '2026-03-13T00:00:01Z' 'feedface' > '$global_completed_root/ZZ-003'
  next=\$(clasp_swarm_select_next_ready_task '$lane_root' '$completed_root' '$global_completed_root' '$blocked_root')
  [[ \$(basename \"\$next\") == 'ZZ-001-late-consumer.md' ]]
" >/dev/null

invalid_lane_root="$(mktemp -d)"

cat > "$invalid_lane_root/ZZ-004-invalid-manifest.md" <<'EOF'
# ZZ-004

## Goal

Missing title and the required structured sections.
EOF

set +e
invalid_output="$(bash "$project_root/scripts/clasp-swarm-lane.sh" --list-tasks "$invalid_lane_root" 2>&1)"
invalid_status="$?"
set -e

if [[ "$invalid_status" -eq 0 ]]; then
  echo "expected invalid manifest listing to fail" >&2
  exit 1
fi

if [[ "$invalid_output" != *"manifest.title must be a non-empty string"* ]]; then
  echo "expected invalid manifest error to mention title validation" >&2
  printf '%s\n' "$invalid_output" >&2
  exit 1
fi

prompt_test_root="$(mktemp -d)"
prompt_project_root="$(make_prompt_test_project "$prompt_test_root")"

cat > "$prompt_project_root/task-literal.md" <<'EOF'
# PX-001 Prompt literal

## Goal

Keep shell markers literal: $(printf prompt-substitution) `${HOME}` `touch /tmp/prompt`.

## Why

Regression coverage should catch prompt interpolation bugs.

## Scope

- Preserve $(printf scope-substitution) and ${USER} literally

## Likely Files

- `scripts/clasp-builder.sh`

## Dependencies

- None

## Acceptance

- Preserve `$(printf acceptance-substitution)` and `${PATH}` in the prompt

## Verification

```sh
bash scripts/verify-all.sh
```
EOF

cat > "$prompt_project_root/feedback.json" <<'EOF'
{
  "summary": "Previous verifier said $(printf verifier-summary) should stay literal.",
  "findings": [
    "Do not execute ${HOME} while rendering feedback."
  ],
  "follow_up": [
    "Keep `touch /tmp/feedback` as plain text."
  ]
}
EOF

mkdir -p "$prompt_project_root/workspace" "$prompt_project_root/baseline" "$prompt_project_root/run"

bash -lc "
  set -euo pipefail
  cd '$prompt_project_root'
  PATH='$prompt_project_root/tools':\"\$PATH\" HOME='$prompt_project_root/home' \
    CLASP_TEST_CODEX_MODE=builder \
    CLASP_TEST_PROMPT_CAPTURE='$prompt_project_root/builder.prompt' \
    bash scripts/clasp-builder.sh \
      '$prompt_project_root/task-literal.md' \
      '$prompt_project_root/workspace' \
      '$prompt_project_root/run/builder-report.json' \
      '$prompt_project_root/run/builder-log.jsonl' \
      '$prompt_project_root/feedback.json'

  grep -F '\$(printf prompt-substitution)' '$prompt_project_root/builder.prompt' >/dev/null
  grep -F '\${HOME}' '$prompt_project_root/builder.prompt' >/dev/null
  grep -F 'Previous verifier said \$(printf verifier-summary) should stay literal.' '$prompt_project_root/builder.prompt' >/dev/null
  grep -F 'touch /tmp/feedback' '$prompt_project_root/builder.prompt' >/dev/null

  PATH='$prompt_project_root/tools':\"\$PATH\" HOME='$prompt_project_root/home' \
    CLASP_TEST_CODEX_MODE=verifier \
    CLASP_TEST_PROMPT_CAPTURE='$prompt_project_root/verifier.prompt' \
    bash scripts/clasp-verifier.sh \
      '$prompt_project_root/task-literal.md' \
      '$prompt_project_root/workspace' \
      '$prompt_project_root/baseline' \
      '$prompt_project_root/run/verifier-report.json' \
      '$prompt_project_root/run/verifier-log.jsonl'

  grep -F 'Baseline workspace: $prompt_project_root/baseline' '$prompt_project_root/verifier.prompt' >/dev/null
  grep -F '\$(printf prompt-substitution)' '$prompt_project_root/verifier.prompt' >/dev/null
  grep -F '\${HOME}' '$prompt_project_root/verifier.prompt' >/dev/null
" >/dev/null

prompt_test_root_2="$(mktemp -d)"
prompt_project_root_2="$(make_prompt_test_project "$prompt_test_root_2")"

{
  cat <<'EOF'
# PX-002 Oversized prompt

## Goal

Force the prompt-size guard to fire before codex runs.

## Why

Large manifests should fail with a direct error instead of a late model-side failure.

## Scope

- Keep this file large

## Likely Files

- `scripts/clasp-builder.sh`

## Dependencies

- None

## Acceptance

- fail early

## Verification

```sh
bash scripts/verify-all.sh
```

EOF
  printf '%4096s\n' '' | tr ' ' 'x'
} > "$prompt_project_root_2/task-oversized.md"

mkdir -p "$prompt_project_root_2/workspace" "$prompt_project_root_2/baseline" "$prompt_project_root_2/run"

bash -lc "
  set -euo pipefail
  cd '$prompt_project_root_2'

  set +e
  builder_output=\$(PATH='$prompt_project_root_2/tools':\"\$PATH\" HOME='$prompt_project_root_2/home' \
    CLASP_SWARM_PROMPT_MAX_BYTES=512 \
    CLASP_TEST_CODEX_MODE=builder \
    CLASP_TEST_PROMPT_CAPTURE='$prompt_project_root_2/builder.prompt' \
    bash scripts/clasp-builder.sh \
      '$prompt_project_root_2/task-oversized.md' \
      '$prompt_project_root_2/workspace' \
      '$prompt_project_root_2/run/builder-report.json' \
      '$prompt_project_root_2/run/builder-log.jsonl' 2>&1)
  builder_status=\$?

  verifier_output=\$(PATH='$prompt_project_root_2/tools':\"\$PATH\" HOME='$prompt_project_root_2/home' \
    CLASP_SWARM_PROMPT_MAX_BYTES=512 \
    CLASP_TEST_CODEX_MODE=verifier \
    CLASP_TEST_PROMPT_CAPTURE='$prompt_project_root_2/verifier.prompt' \
    bash scripts/clasp-verifier.sh \
      '$prompt_project_root_2/task-oversized.md' \
      '$prompt_project_root_2/workspace' \
      '$prompt_project_root_2/baseline' \
      '$prompt_project_root_2/run/verifier-report.json' \
      '$prompt_project_root_2/run/verifier-log.jsonl' 2>&1)
  verifier_status=\$?
  set -e

  [[ \$builder_status -ne 0 ]]
  [[ \$verifier_status -ne 0 ]]
  [[ \"\$builder_output\" == *'builder prompt is '* ]]
  [[ \"\$builder_output\" == *'CLASP_SWARM_PROMPT_MAX_BYTES=512'* ]]
  [[ \"\$verifier_output\" == *'verifier prompt is '* ]]
  [[ \"\$verifier_output\" == *'CLASP_SWARM_PROMPT_MAX_BYTES=512'* ]]
  [[ ! -f '$prompt_project_root_2/builder.prompt' ]]
  [[ ! -f '$prompt_project_root_2/verifier.prompt' ]]
" >/dev/null

lane_merge_test_root="$(mktemp -d)"
lane_merge_project_root="$(make_lane_merge_test_project "$lane_merge_test_root")"

bash -lc "
  set -euo pipefail
  cd '$lane_merge_project_root'
  bash scripts/clasp-swarm-lane.sh agents/swarm/test-wave/01-merge-gate >/dev/null 2>&1

  [[ \$(git rev-parse main) == \$(git rev-parse agents/swarm-trunk) ]]
  [[ \$(< feature.txt) == 'builder-change' ]]
  [[ \$(< verifier-only.txt) == 'verified-by-verifier' ]]
  [[ ! -e remove-me.txt ]]
  [[ -f .clasp-swarm/test-wave/01-merge-gate/completed/SW-005 ]]
  run_dir=\$(find .clasp-swarm/test-wave/01-merge-gate/runs -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [[ -n \"\$run_dir\" ]]
  [[ -f \"\$run_dir/integration.log\" ]]
" >/dev/null

lane_cleanup_test_root="$(mktemp -d)"
lane_cleanup_project_root="$(make_lane_cleanup_test_project "$lane_cleanup_test_root")"

bash -lc "
  set -euo pipefail
  cd '$lane_cleanup_project_root'
  git branch agents/swarm-trunk >/dev/null

  runtime_root='.clasp-swarm/test-wave/01-cleanup'
  runs_root=\"\$runtime_root/runs\"
  stale_run=\"\$runs_root/20260314T120000Z-SW-006-cleanup-attempt1\"
  external_root=\$(cd .. && pwd)
  worktrees_root=\"\$external_root/.clasp-agent-worktrees/\$(basename \"\$PWD\")/test-wave/01-cleanup\"
  task_worktree=\"\$worktrees_root/SW-006-cleanup\"
  task_branch='agents/swarm/test-wave/01-cleanup/SW-006-cleanup'

  mkdir -p \"\$stale_run\"
  git worktree add --force -B \"\$task_branch\" \"\$task_worktree\" agents/swarm-trunk >/dev/null
  printf 'stale-worktree\n' > \"\$task_worktree/feature.txt\"
  mkdir -p \"\$stale_run/baseline-worktree\"
  printf '%s\n' 999999 > \"\$runtime_root/pid\"

  bash scripts/clasp-swarm-lane.sh agents/swarm/test-wave/01-cleanup >/dev/null 2>&1

  [[ ! -d \"\$stale_run\" ]]
  [[ ! -d \"\$task_worktree\" ]]
  ! git worktree list --porcelain | grep -Fqx \"worktree \$task_worktree\"
  ! git show-ref --verify --quiet \"refs/heads/\$task_branch\"

  run_count=\$(find \"\$runs_root\" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')
  [[ \"\$run_count\" == '1' ]]
  latest_run=\$(find \"\$runs_root\" -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [[ \$(basename \"\$latest_run\") == *'-SW-006-cleanup-attempt1' ]]
  [[ -f \"\$latest_run/builder-report.json\" ]]
  [[ -f \"\$latest_run/verifier-report.json\" ]]
  [[ -f .clasp-swarm/completed/SW-006 ]]
  [[ \"\$(< feature.txt)\" == 'fresh-builder-change' ]]
  bash scripts/verify-all.sh
" >/dev/null

autopilot_test_root="$(mktemp -d)"
autopilot_project_root="$(make_autopilot_test_project "$autopilot_test_root" "pass-workaround")"
write_task_manifest "$autopilot_project_root/agents/tasks/AA-001-parent.md" "AA-001 Parent" "None"

bash -lc "
  set -euo pipefail
  cd '$autopilot_project_root'
  PATH='$autopilot_project_root/tools':\"\$PATH\" CLASP_AUTOPILOT_RETRY_LIMIT=2 bash scripts/clasp-autopilot.sh >/dev/null 2>&1

  [[ -f .clasp-agents/completed/AA-001-parent ]]
  [[ ! -f .clasp-agents/blocked/AA-001-parent.json ]]
  [[ ! -f .clasp-agents/generated-tasks/AA-001-parent--workaround.md ]]
  [[ \$(< test-events.log) == \$'builder:AA-001-parent\nverifier:AA-001-parent:fail\nbuilder:AA-001-parent\nverifier:AA-001-parent:fail\nbuilder:AA-001-parent--workaround\nverifier:AA-001-parent--workaround:pass\nbuilder:AA-001-parent\nverifier:AA-001-parent:pass' ]]
" >/dev/null

autopilot_test_root_2="$(mktemp -d)"
autopilot_project_root_2="$(make_autopilot_test_project "$autopilot_test_root_2" "fail-workaround")"
write_task_manifest "$autopilot_project_root_2/agents/tasks/AA-001-parent.md" "AA-001 Parent" "None"
write_task_manifest "$autopilot_project_root_2/agents/tasks/AA-002-later.md" "AA-002 Later" "None"

bash -lc "
  set -euo pipefail
  cd '$autopilot_project_root_2'
  PATH='$autopilot_project_root_2/tools':\"\$PATH\" CLASP_AUTOPILOT_RETRY_LIMIT=2 bash scripts/clasp-autopilot.sh >/dev/null 2>&1

  [[ -f .clasp-agents/completed/AA-002-later ]]
  [[ ! -f .clasp-agents/completed/AA-001-parent ]]
  [[ -f .clasp-agents/blocked/AA-001-parent.json ]]
  [[ -f .clasp-agents/blocked/AA-001-parent--workaround.json ]]
  [[ -f .clasp-agents/generated-tasks/AA-001-parent--workaround.md ]]
  [[ \$(< test-events.log) == \$'builder:AA-001-parent\nverifier:AA-001-parent:fail\nbuilder:AA-001-parent\nverifier:AA-001-parent:fail\nbuilder:AA-001-parent--workaround\nverifier:AA-001-parent--workaround:fail\nbuilder:AA-001-parent--workaround\nverifier:AA-001-parent--workaround:fail\nbuilder:AA-002-later\nverifier:AA-002-later:pass' ]]
" >/dev/null
