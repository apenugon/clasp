#!/usr/bin/env bash
set -euo pipefail

report_test_failure() {
  local status=$?
  printf "test-swarm-control: failed at line %s: %s\n" "$1" "$2" >&2
  exit "$status"
}

trap 'report_test_failure "$LINENO" "$BASH_COMMAND"' ERR

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLASP_VERIFY_IN_PROGRESS=1
export CLASP_VERIFY_ACTIVE_ROOT="$project_root"
export CLASP_ALLOW_UNMANAGED_AGENT_RUNTIME=1
export CLASP_TEST_CODEX_MODE=builder
export CLASP_SWARM_CHILD_MIN_AVAILABLE_MEMORY_MB="${CLASP_SWARM_CHILD_MIN_AVAILABLE_MEMORY_MB:-1}"
export CLASP_SWARM_CHILD_MIN_AVAILABLE_DISK_MB="${CLASP_SWARM_CHILD_MIN_AVAILABLE_DISK_MB:-0}"
export CLASP_SWARM_CHILD_MIN_DISK_HEADROOM_MB="${CLASP_SWARM_CHILD_MIN_DISK_HEADROOM_MB:-0}"
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
autopilot_test_root_3=""
lane_merge_test_root=""
lane_merge_gate_snapshot_test_root=""
lane_cleanup_test_root=""
lane_worktree_retry_test_root=""
batch_start_test_root=""
swarm_managed_admission_test_root=""
swarm_child_admission_test_root=""
swarm_child_retryable_admission_test_root=""
prompt_test_root=""
prompt_test_root_2=""
task_file_drain_test_root=""
status_wave_name=""
status_lane_root_1=""
status_lane_root_2=""
status_lane_root_3=""
status_lane_root_4=""
status_lane_root_5=""
status_lane_root_6=""
status_runtime_root_1=""
status_runtime_root_2=""
status_runtime_root_3=""
status_runtime_root_4=""
status_runtime_root_5=""
status_runtime_root_6=""
status_text_output=""
status_json_output=""
status_live_pid=""
stop_child_wave_name=""
stop_child_lane_root=""
stop_child_runtime_root=""
summary_wave_name=""
summary_lane_root_1=""
summary_lane_root_2=""
summary_runtime_root_1=""
summary_runtime_root_2=""
summary_text_output=""
summary_json_output=""
summary_markdown_output=""

cleanup() {
  if [[ -n "${status_live_pid:-}" ]]; then
    kill "${status_live_pid}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${stop_child_runtime_root:-}" && -d "$stop_child_runtime_root/child-jobs" ]]; then
    while IFS= read -r child_job_dir; do
      [[ -n "$child_job_dir" ]] || continue
      "$project_root/scripts/stop-managed-job.sh" \
        --jobs-root "$stop_child_runtime_root/child-jobs" \
        "$child_job_dir" >/dev/null 2>&1 || true
    done < <(find "$stop_child_runtime_root/child-jobs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)
  fi
  rm -rf "${runs_root:-}" "${markers_root:-}" "${repo_root:-}" "${lane_root:-}" "${completed_root:-}" "${blocked_root:-}" "${global_completed_root:-}" "${spawn_root:-}" "${spawn_path_root:-}" "${invalid_lane_root:-}" "${autopilot_test_root:-}" "${autopilot_test_root_2:-}" "${autopilot_test_root_3:-}" "${lane_merge_test_root:-}" "${lane_merge_gate_snapshot_test_root:-}" "${lane_cleanup_test_root:-}" "${lane_worktree_retry_test_root:-}" "${batch_start_test_root:-}" "${swarm_managed_admission_test_root:-}" "${swarm_child_admission_test_root:-}" "${swarm_child_retryable_admission_test_root:-}" "${prompt_test_root:-}" "${prompt_test_root_2:-}" "${task_file_drain_test_root:-}" "${status_lane_root_1:-}" "${status_lane_root_2:-}" "${status_lane_root_3:-}" "${status_lane_root_4:-}" "${status_lane_root_5:-}" "${status_lane_root_6:-}" "${status_runtime_root_1:-}" "${status_runtime_root_2:-}" "${status_runtime_root_3:-}" "${status_runtime_root_4:-}" "${status_runtime_root_5:-}" "${status_runtime_root_6:-}" "${stop_child_lane_root:-}" "${stop_child_runtime_root:-}" "${summary_lane_root_1:-}" "${summary_lane_root_2:-}" "${summary_runtime_root_1:-}" "${summary_runtime_root_2:-}"
  rm -f "${status_text_output:-}" "${status_json_output:-}" "${summary_text_output:-}" "${summary_json_output:-}" "${summary_markdown_output:-}"
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

if [[ -n "${CLASP_TEST_ENV_CAPTURE:-}" ]]; then
  cat > "$CLASP_TEST_ENV_CAPTURE" <<ENV
HOME=$HOME
XDG_CACHE_HOME=${XDG_CACHE_HOME:-}
XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-}
XDG_DATA_HOME=${XDG_DATA_HOME:-}
XDG_STATE_HOME=${XDG_STATE_HOME:-}
TMPDIR=${TMPDIR:-}
CODEX_HOME=${CODEX_HOME:-}
ENV
fi

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
  cp "$project_root/scripts/clasp-swarm-common.sh" "$project_dir/scripts/clasp-swarm-common.sh"
  cp "$project_root/scripts/clasp-autopilot.sh" "$project_dir/scripts/clasp-autopilot.sh"
  cp "$project_root/scripts/clasp-codex-loop.sh" "$project_dir/scripts/clasp-codex-loop.sh"
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
    "$project_dir/scripts/clasp-codex-loop.sh" \
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
    "$project_root/scripts/run-managed-job.sh" \
    "$project_root/scripts/stop-managed-job.sh" \
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
    "$project_dir/scripts/run-managed-job.sh" \
    "$project_dir/scripts/stop-managed-job.sh" \
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
    printf '.clasp-swarm/\n' > .gitignore
    printf 'base\n' > feature.txt
    printf 'remove-this\n' > remove-me.txt
    git add .
    git commit -m 'base snapshot' >/dev/null
  )

  printf '%s\n' "$project_dir"
}

make_lane_merge_snapshot_gate_test_project() {
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
    "$project_root/scripts/run-managed-job.sh" \
    "$project_root/scripts/stop-managed-job.sh" \
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

cat > "$report_json" <<JSON
{
  "verdict": "pass",
  "summary": "verified $task_id",
  "findings": [],
  "tests_run": [
    "verified snapshot capture scenario"
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
EOF

  chmod +x \
    "$project_dir/scripts/clasp-builder.sh" \
    "$project_dir/scripts/clasp-swarm-common.sh" \
    "$project_dir/scripts/clasp-swarm-lane.sh" \
    "$project_dir/scripts/clasp-swarm-validate-task.mjs" \
    "$project_dir/scripts/run-managed-job.sh" \
    "$project_dir/scripts/stop-managed-job.sh" \
    "$project_dir/scripts/clasp-verifier.sh" \
    "$project_dir/scripts/verify-all.sh"

  cat > "$project_dir/agents/swarm/test-wave/01-merge-gate/SW-005-verified-snapshot.md" <<'EOF'
# SW-005 Verified snapshot

## Goal

Verify that the merge gate copies only the verified workspace snapshot into the accepted snapshot.

## Why

Regression coverage for post-verifier task workspace mutations should stay end-to-end.

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
    printf '.clasp-swarm/\n' > .gitignore
    printf 'base\n' > feature.txt
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
    "$project_root/scripts/run-managed-job.sh" \
    "$project_root/scripts/stop-managed-job.sh" \
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
    "$project_dir/scripts/run-managed-job.sh" \
    "$project_dir/scripts/stop-managed-job.sh" \
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

make_lane_worktree_retry_test_project() {
  local target_root="$1"
  local project_dir="$target_root/repo"

  mkdir -p \
    "$project_dir/scripts" \
    "$project_dir/agents/swarm/test-wave/01-worktree-retry"

  cp \
    "$project_root/scripts/clasp-swarm-common.sh" \
    "$project_root/scripts/clasp-swarm-lane.sh" \
    "$project_root/scripts/clasp-swarm-validate-task.mjs" \
    "$project_root/scripts/run-managed-job.sh" \
    "$project_root/scripts/stop-managed-job.sh" \
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
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
attempt_file="$project_root/builder-attempt.txt"
attempt=0

if [[ -f "$attempt_file" ]]; then
  attempt="$(< "$attempt_file")"
fi
attempt=$((attempt + 1))
printf '%s\n' "$attempt" > "$attempt_file"

if [[ "$attempt" == "1" ]]; then
  rm -f "$workspace/.git"
  printf 'builder stripped git metadata\n' > "$log_jsonl"
  cat > "$report_json" <<JSON
{
  "summary": "builder finished for $task_id",
  "files_touched": [],
  "tests_run": [],
  "residual_risks": []
}
JSON
  exit 0
fi

printf 'recovered-builder-change\n' > "$workspace/feature.txt"

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

printf 'builder retry preserved git metadata\n' > "$log_jsonl"
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
[[ "$(< "$workspace/feature.txt")" == "recovered-builder-change" ]]

cat > "$report_json" <<JSON
{
  "verdict": "pass",
  "summary": "verified $task_id",
  "findings": [],
  "tests_run": [
    "broken worktree retry scenario"
  ],
  "follow_up": []
}
JSON

: > "$log_jsonl"
EOF

  cat > "$project_dir/scripts/verify-all.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ "$(< feature.txt)" == "recovered-builder-change" ]]
EOF

  chmod +x \
    "$project_dir/scripts/clasp-builder.sh" \
    "$project_dir/scripts/clasp-swarm-common.sh" \
    "$project_dir/scripts/clasp-swarm-lane.sh" \
    "$project_dir/scripts/clasp-swarm-validate-task.mjs" \
    "$project_dir/scripts/run-managed-job.sh" \
    "$project_dir/scripts/stop-managed-job.sh" \
    "$project_dir/scripts/clasp-verifier.sh" \
    "$project_dir/scripts/verify-all.sh"

  cat > "$project_dir/agents/swarm/test-wave/01-worktree-retry/SW-007-worktree-retry.md" <<'EOF'
# SW-007 Worktree retry

## Goal

Retry the lane after a builder leaves the task workspace without usable Git metadata.

## Why

Regression coverage for builder-side workspace corruption should stay end-to-end.

## Scope

- Exercise one retry after an infra failure

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

make_batch_start_test_project() {
  local target_root="$1"
  local project_dir="$target_root/repo"

  mkdir -p \
    "$project_dir/scripts" \
    "$project_dir/agents/swarm/test-wave/01-foundation-a" \
    "$project_dir/agents/swarm/test-wave/02-foundation-b" \
    "$project_dir/agents/swarm/test-wave/03-follow-up"

  cp \
    "$project_root/scripts/clasp-swarm-common.sh" \
    "$project_root/scripts/clasp-swarm-lane.sh" \
    "$project_root/scripts/clasp-swarm-start.sh" \
    "$project_root/scripts/clasp-swarm-stop.sh" \
    "$project_root/scripts/clasp-swarm-status.sh" \
    "$project_root/scripts/run-managed-job.sh" \
    "$project_root/scripts/stop-managed-job.sh" \
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
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

printf '%s\n' "$task_id" >> "$project_root/builder-events.log"
printf '%s CLASP_NATIVE_JOBS_MAX=%s\n' "$task_id" "${CLASP_NATIVE_JOBS_MAX:-}" >> "$project_root/builder-env.log"
printf '%s\n' "$task_id" > "$workspace/$task_id.txt"
if [[ -n "${CLASP_SWARM_TEST_BUILDER_SLEEP_SECS:-}" ]]; then
  sleep "$CLASP_SWARM_TEST_BUILDER_SLEEP_SECS"
fi

cat > "$report_json" <<JSON
{
  "summary": "builder finished for $task_id",
  "files_touched": [
    "$task_id.txt"
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

[[ -f "$workspace/$task_id.txt" ]]

cat > "$report_json" <<JSON
{
  "verdict": "pass",
  "summary": "verified $task_id",
  "findings": [],
  "tests_run": [
    "batch start scenario"
  ],
  "follow_up": []
}
JSON

: > "$log_jsonl"
EOF

  cat > "$project_dir/scripts/verify-all.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF

  chmod +x \
    "$project_dir/scripts/clasp-builder.sh" \
    "$project_dir/scripts/clasp-swarm-common.sh" \
    "$project_dir/scripts/clasp-swarm-lane.sh" \
    "$project_dir/scripts/clasp-swarm-start.sh" \
    "$project_dir/scripts/clasp-swarm-status.sh" \
    "$project_dir/scripts/clasp-swarm-stop.sh" \
    "$project_dir/scripts/run-managed-job.sh" \
    "$project_dir/scripts/stop-managed-job.sh" \
    "$project_dir/scripts/clasp-swarm-validate-task.mjs" \
    "$project_dir/scripts/clasp-verifier.sh" \
    "$project_dir/scripts/verify-all.sh"

  cat > "$project_dir/agents/swarm/test-wave/01-foundation-a/BA-001-foundation-a.md" <<'EOF'
# BA-001 Foundation a

## Goal

Run the first foundation task.

## Why

Exercise batch-filtered swarm startup.

## Scope

- Complete in the foundation batch

## Likely Files

- `scripts/clasp-swarm-start.sh`

## Batch

foundation

## Dependencies

- None

## Acceptance

- done

## Verification

```sh
bash scripts/verify-all.sh
```
EOF

  cat > "$project_dir/agents/swarm/test-wave/02-foundation-b/BA-002-foundation-b.md" <<'EOF'
# BA-002 Foundation b

## Goal

Run the second foundation task.

## Why

Exercise batch-filtered swarm startup across lanes.

## Scope

- Complete in the foundation batch

## Likely Files

- `scripts/clasp-swarm-start.sh`

## Batch

foundation

## Dependencies

- None

## Acceptance

- done

## Verification

```sh
bash scripts/verify-all.sh
```
EOF

  cat > "$project_dir/agents/swarm/test-wave/03-follow-up/BA-003-follow-up.md" <<'EOF'
# BA-003 Follow up

## Goal

Run only after the full foundation batch completes.

## Why

Exercise dependency labels for batch completion.

## Scope

- Wait for the foundation batch label

## Likely Files

- `scripts/clasp-swarm-lane.sh`

## Dependencies

- None

## Dependency Labels

- foundation

## Acceptance

- done

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

grep -F --quiet 'sandbox_mode="${CLASP_SWARM_CODEX_SANDBOX:-danger-full-access}"' "$project_root/scripts/clasp-builder.sh"
grep -F --quiet -- '--sandbox "$sandbox_mode"' "$project_root/scripts/clasp-builder.sh"
! grep -F --quiet -- '--dangerously-bypass-approvals-and-sandbox' "$project_root/scripts/clasp-builder.sh"
grep -F --quiet 'sandbox_mode="${CLASP_SWARM_CODEX_SANDBOX:-danger-full-access}"' "$project_root/scripts/clasp-verifier.sh"
grep -F --quiet -- '--sandbox "$sandbox_mode"' "$project_root/scripts/clasp-verifier.sh"
grep -F --quiet 'builder_timeout_seconds="${CLASP_SWARM_BUILDER_TIMEOUT_SECONDS:-0}"' "$project_root/scripts/clasp-swarm-lane.sh"
grep -F --quiet 'if [[ -z "$timeout_seconds" || "$timeout_seconds" == "0" ]]; then' "$project_root/scripts/clasp-swarm-lane.sh"
grep -F --quiet 'manage_child_subprocesses="${CLASP_SWARM_MANAGE_CHILD_SUBPROCESSES:-1}"' "$project_root/scripts/clasp-swarm-lane.sh"
grep -F --quiet 'child_memory_mb="${CLASP_SWARM_CHILD_MEMORY_MB:-${CLASP_SWARM_LANE_MEMORY_MB:-8192}}"' "$project_root/scripts/clasp-swarm-lane.sh"
grep -F --quiet 'run_lane_managed_subprocess "$timeout_seconds" "$@"' "$project_root/scripts/clasp-swarm-lane.sh"
grep -F --quiet -- '--jobs-root "$child_jobs_root"' "$project_root/scripts/clasp-swarm-lane.sh"
grep -F --quiet 'active_child_job_dir="$job_dir"' "$project_root/scripts/clasp-swarm-lane.sh"
grep -F --quiet 'last_child_job_is_resource_guard_failure' "$project_root/scripts/clasp-swarm-lane.sh"
grep -F --quiet 'write_resource_guard_failure_report' "$project_root/scripts/clasp-swarm-lane.sh"
grep -F --quiet 'blocked on $task_id after builder resource guard' "$project_root/scripts/clasp-swarm-lane.sh"
grep -F --quiet 'resource_guard_block_mode="${CLASP_SWARM_RESOURCE_GUARD_BLOCK_MODE:-fail-closed}"' "$project_root/scripts/clasp-swarm-lane.sh"
grep -F --quiet 'deferred retry for $task_id after builder resource guard' "$project_root/scripts/clasp-swarm-lane.sh"
grep -F --quiet 'export CLASP_SWARM_RESOURCE_GUARD_BLOCK_MODE=retryable' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root scripts/run-managed-job.sh --jobs-root "$PWD/.clasp-swarm/test-wave/01-foundation-a/jobs"' "$project_root/scripts/test-swarm-control.sh"
grep -F --quiet 'CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root scripts/run-managed-job.sh --jobs-root "$PWD/.clasp-swarm/test-wave/02-foundation-b/jobs"' "$project_root/scripts/test-swarm-control.sh"
grep -F --quiet 'CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root scripts/run-managed-job.sh --jobs-root "$PWD/.clasp-swarm/test-wave/01-foundation-a/child-jobs"' "$project_root/scripts/test-swarm-control.sh"
grep -F --quiet 'CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root bash scripts/clasp-swarm-start.sh --batch foundation test-wave' "$project_root/scripts/test-swarm-control.sh"
grep -F --quiet 'CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root bash scripts/clasp-swarm-lane.sh agents/swarm/test-wave/01-foundation-a' "$project_root/scripts/test-swarm-control.sh"
grep -F --quiet 'preflight-complete' "$project_root/scripts/clasp-swarm-common.sh"
grep -F --quiet 'max_running_lanes="${CLASP_SWARM_MAX_RUNNING_LANES:-1}"' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'lane_memory_mb="${CLASP_SWARM_LANE_MEMORY_MB:-8192}"' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'min_available_memory_mb="${CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB:-45056}"' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'min_available_disk_mb="${CLASP_SWARM_MIN_AVAILABLE_DISK_MB:-16384}"' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'min_disk_headroom_mb="${CLASP_SWARM_MIN_DISK_HEADROOM_MB:-${CLASP_GENERATED_STATE_MIN_HEADROOM_MB:-1024}}"' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'native_jobs_max="${CLASP_SWARM_NATIVE_JOBS_MAX:-1}"' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'native_bundle_jobs="${CLASP_SWARM_NATIVE_BUNDLE_JOBS:-1}"' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'native_image_section_jobs="${CLASP_SWARM_NATIVE_IMAGE_SECTION_JOBS:-1}"' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'native_image_section_jobs_max="${CLASP_SWARM_NATIVE_IMAGE_SECTION_JOBS_MAX:-1}"' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'required_available_memory_mb=$((required_available_memory_mb + (lane_memory_mb * (running_lanes + 1))))' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'managed_job_args+=(--min-available-memory-mb "$min_available_memory_mb")' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'managed_job_args+=(--min-available-disk-mb "$min_available_disk_mb" --disk-reserve-path "$project_root")' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'managed_job_args+=(--min-disk-headroom-mb "$min_disk_headroom_mb" --disk-reserve-path "$project_root")' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'CLASP_SWARM_CHILD_MEMORY_MB="${CLASP_SWARM_CHILD_MEMORY_MB:-$lane_memory_mb}"' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'CLASP_SWARM_CHILD_MIN_AVAILABLE_MEMORY_MB="${CLASP_SWARM_CHILD_MIN_AVAILABLE_MEMORY_MB:-$min_available_memory_mb}"' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'CLASP_NATIVE_JOBS_MAX="$native_jobs_max"' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'CLASP_NATIVE_BUNDLE_JOBS="$native_bundle_jobs"' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'CLASP_NATIVE_IMAGE_SECTION_JOBS_MAX="$native_image_section_jobs_max"' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'resource guard: not starting lane=$lane_name' "$project_root/scripts/clasp-swarm-start.sh"
grep -F --quiet 'force_signal_args=(--force-signal)' "$project_root/scripts/clasp-swarm-stop.sh"
grep -F --quiet '"${force_signal_args[@]}" --jobs-root' "$project_root/scripts/clasp-swarm-stop.sh"
grep -F --quiet 'stop_child_managed_jobs "$lane_name" "$runtime_root"' "$project_root/scripts/clasp-swarm-stop.sh"
grep -F --quiet -- '--jobs-root "$child_jobs_root"' "$project_root/scripts/clasp-swarm-stop.sh"
! grep -F --quiet -- '--dangerously-bypass-approvals-and-sandbox' "$project_root/scripts/clasp-verifier.sh"

bash -lc "
  set -euo pipefail
  source '$project_root/scripts/clasp-swarm-common.sh'
  [[ \$(clasp_swarm_task_key 'SW-001-do-something.md') == 'SW-001' ]]
  [[ \$(clasp_swarm_task_key 'agents/swarm/full/02-core-language/LG-019-type-inference.md') == 'LG-019' ]]
  node '$project_root/scripts/clasp-swarm-validate-task.mjs' '$project_root/agents/swarm/full/01-swarm-infra/SW-001-replace-the-current-coarse-agents-tasks-backlog-with-a-granular-task-manifest-template-and-task-schema.md' >/dev/null
  [[ \$(node '$project_root/scripts/clasp-swarm-validate-task.mjs' --print-field taskId '$project_root/agents/swarm/full/01-swarm-infra/SW-001-replace-the-current-coarse-agents-tasks-backlog-with-a-granular-task-manifest-template-and-task-schema.md') == 'SW-001-replace-the-current-coarse-agents-tasks-backlog-with-a-granular-task-manifest-template-and-task-schema' ]]
  [[ \$(node '$project_root/scripts/clasp-swarm-validate-task.mjs' --print-field taskKey '$project_root/agents/swarm/full/01-swarm-infra/SW-001-replace-the-current-coarse-agents-tasks-backlog-with-a-granular-task-manifest-template-and-task-schema.md') == 'SW-001' ]]
  [[ \$(node '$project_root/scripts/clasp-swarm-validate-task.mjs' --print-field batchLabel '$project_root/agents/swarm/full/01-swarm-infra/SW-001-replace-the-current-coarse-agents-tasks-backlog-with-a-granular-task-manifest-template-and-task-schema.md') == '' ]]
  [[ \$(node '$project_root/scripts/clasp-swarm-validate-task.mjs' --print-field batchLabel '$project_root/agents/swarm/full/01-swarm-infra/SW-002-add-tests-for-autopilot-queue-behavior-especially-blocked-task-handling-workaround-generation-and-restart-behavior.md') == '' ]]
  [[ \$(node '$project_root/scripts/clasp-swarm-validate-task.mjs' --print-field dependencies '$project_root/agents/swarm/full/01-swarm-infra/SW-003-add-prompt-building-tests-so-builder-verifier-scripts-cannot-regress-into-shell-interpolation-or-oversized-prompt-failures.md') == 'SW-002' ]]
  [[ \$(node '$project_root/scripts/clasp-swarm-validate-task.mjs' --print-field dependencyLabels '$project_root/agents/swarm/full/01-swarm-infra/SW-005-add-a-merge-gate-that-copies-only-verified-workspace-changes-into-the-accepted-snapshot.md') == '' ]]
  summary_row=\$(clasp_swarm_task_manifest_rows '$project_root/agents/swarm/full/01-swarm-infra/SW-003-add-prompt-building-tests-so-builder-verifier-scripts-cannot-regress-into-shell-interpolation-or-oversized-prompt-failures.md')
  IFS=\$'\037' read -r summary_path summary_key summary_batch summary_dependencies summary_dependency_labels <<< \"\${summary_row//\$'\t'/\$'\037'}\"
  [[ \"\$summary_key\" == 'SW-003' ]]
  [[ \"\$summary_batch\" == '' ]]
  [[ \"\$summary_dependencies\" == 'SW-002' ]]
  [[ \"\$summary_dependency_labels\" == '' ]]
  [[ -z \$(bash '$project_root/scripts/clasp-swarm-start.sh' --list-batches full) ]]
  clasp_swarm_retry_limit_is_bounded '2'
  ! clasp_swarm_retry_limit_is_bounded '0'
  ! clasp_swarm_retry_limit_is_bounded '-1'
  ! clasp_swarm_retry_limit_is_bounded 'forever'
" >/dev/null

spawn_root="$(mktemp -d)"
spawn_path_root="$(mktemp -d)"
spawn_bash_bin="$(command -v bash)"
spawn_python3_bin="$(command -v python3 || true)"

if [[ -x /bin/bash ]]; then
  spawn_bash_bin="/bin/bash"
fi

if [[ -x /usr/bin/python3 ]]; then
  spawn_python3_bin="/usr/bin/python3"
fi

ln -s "$spawn_bash_bin" "$spawn_path_root/bash"
if [[ -n "$spawn_python3_bin" ]]; then
  ln -s "$spawn_python3_bin" "$spawn_path_root/python3"
fi
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
  git -C \"\$repo_root\" commit --allow-empty -m 'GF-001 completed through git fallback' >/dev/null
  git -C \"\$repo_root\" branch agents/swarm-trunk

  mkdir -p \"\$repo_root/.clasp-swarm/completed\" \"\$repo_root/not-global-completed\"
  clasp_swarm_task_is_completed \"\$repo_root/.clasp-swarm/completed\" GF-001 \"\$repo_root\" main agents/swarm-trunk
  ! clasp_swarm_task_is_completed \"\$repo_root/not-global-completed\" GF-001 \"\$repo_root\" main agents/swarm-trunk
  CLASP_SWARM_GIT_COMPLETION_FALLBACK=always \
    clasp_swarm_task_is_completed \"\$repo_root/not-global-completed\" GF-001 \"\$repo_root\" main agents/swarm-trunk
  ! env CLASP_SWARM_GIT_COMPLETION_FALLBACK=never bash -lc \"source '$project_root/scripts/clasp-swarm-common.sh'; clasp_swarm_task_is_completed '\$repo_root/.clasp-swarm/completed' GF-001 '\$repo_root' main agents/swarm-trunk\"
  unset CLASP_SWARM_GIT_COMPLETION_FALLBACK

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
status_lane_root_3="$project_root/agents/swarm/$status_wave_name/03-interrupted"
status_lane_root_4="$project_root/agents/swarm/$status_wave_name/04-admission"
status_lane_root_5="$project_root/agents/swarm/$status_wave_name/05-enforcer"
status_lane_root_6="$project_root/agents/swarm/$status_wave_name/06-disk"
status_runtime_root_1="$project_root/.clasp-swarm/$status_wave_name/01-active"
status_runtime_root_2="$project_root/.clasp-swarm/$status_wave_name/02-idle"
status_runtime_root_3="$project_root/.clasp-swarm/$status_wave_name/03-interrupted"
status_runtime_root_4="$project_root/.clasp-swarm/$status_wave_name/04-admission"
status_runtime_root_5="$project_root/.clasp-swarm/$status_wave_name/05-enforcer"
status_runtime_root_6="$project_root/.clasp-swarm/$status_wave_name/06-disk"
status_text_output="$(mktemp)"
status_json_output="$(mktemp)"

mkdir -p \
  "$status_runtime_root_1" \
  "$status_runtime_root_2" \
  "$status_lane_root_1" \
  "$status_lane_root_2" \
  "$status_lane_root_3" \
  "$status_lane_root_4" \
  "$status_lane_root_5" \
  "$status_lane_root_6" \
  "$status_runtime_root_1/completed" \
  "$status_runtime_root_1/blocked" \
  "$status_runtime_root_1/runs/20260314T120000Z-AA-100-sample-attempt1" \
  "$status_runtime_root_1/runs/20260314T121500Z-AA-100-sample-attempt2" \
  "$status_runtime_root_2/completed" \
  "$status_runtime_root_2/blocked" \
  "$status_runtime_root_2/child-jobs/clasp-verifier-20260314T122500Z" \
  "$status_runtime_root_2/child-jobs/clasp-builder-20260314T122600Z" \
  "$status_runtime_root_2/runs/20260314T122000Z-BB-200-sample-attempt1" \
  "$status_runtime_root_3/completed" \
  "$status_runtime_root_3/blocked" \
  "$status_runtime_root_3/jobs/stopped-job" \
  "$status_runtime_root_3/child-jobs/clasp-builder-20260314T123001Z" \
  "$status_runtime_root_3/runs/20260314T123000Z-CC-300-interrupted-attempt1" \
  "$status_runtime_root_4/completed" \
  "$status_runtime_root_4/blocked" \
  "$status_runtime_root_4/jobs/admission-job" \
  "$status_runtime_root_4/runs/20260314T124000Z-DD-400-admission-attempt1" \
  "$status_runtime_root_5/completed" \
  "$status_runtime_root_5/blocked" \
  "$status_runtime_root_5/jobs/enforcer-job" \
  "$status_runtime_root_5/runs/20260314T125000Z-EE-500-enforcer-attempt1" \
  "$status_runtime_root_6/completed" \
  "$status_runtime_root_6/blocked" \
  "$status_runtime_root_6/jobs/disk-job" \
  "$status_runtime_root_6/runs/20260314T130000Z-FF-600-disk-attempt1"

cat > "$status_lane_root_3/CC-300-interrupted.md" <<'EOF'
# CC-300 Interrupted

## Goal

Exercise reportless stopped-run status classification.
EOF
cat > "$status_lane_root_4/DD-400-admission.md" <<'EOF'
# DD-400 Admission

## Goal

Exercise reportless admission-lock failure classification.
EOF
cat > "$status_lane_root_5/EE-500-enforcer.md" <<'EOF'
# EE-500 Enforcer

## Goal

Exercise reportless memory-enforcer failure classification.
EOF
cat > "$status_lane_root_6/FF-600-disk.md" <<'EOF'
# FF-600 Disk

## Goal

Exercise reportless disk-guard failure classification and recovery hints.
EOF

printf '%s\n' "AA-100-sample" > "$status_runtime_root_1/current-task.txt"
printf '%s\n' "CC-300-interrupted" > "$status_runtime_root_3/current-task.txt"
printf '%s\n' "DD-400-admission" > "$status_runtime_root_4/current-task.txt"
printf '%s\n' "EE-500-enforcer" > "$status_runtime_root_5/current-task.txt"
printf '%s\n' "FF-600-disk" > "$status_runtime_root_6/current-task.txt"
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
printf '%s\n' "2026-03-14T12:25:00Z" > "$status_runtime_root_2/child-jobs/clasp-verifier-20260314T122500Z/started-at"
printf '%s\n' "memory-exceeded" > "$status_runtime_root_2/child-jobs/clasp-verifier-20260314T122500Z/status"
printf '%s\n' "2026-03-14T12:26:00Z" > "$status_runtime_root_2/child-jobs/clasp-builder-20260314T122600Z/started-at"
printf '%s\n' "started" > "$status_runtime_root_2/child-jobs/clasp-builder-20260314T122600Z/status"
cat > "$status_runtime_root_2/lane.log" <<'EOF'
idle line 1
idle line 2
EOF

printf '%s\n' "$status_runtime_root_3/jobs/stopped-job" > "$status_runtime_root_3/job"
printf '%s\n' "memory-exceeded" > "$status_runtime_root_3/jobs/stopped-job/status"
printf '%s\n' "137" > "$status_runtime_root_3/jobs/stopped-job/exit-status"
printf '%s\n' "512" > "$status_runtime_root_3/jobs/stopped-job/memory-mb"
printf '%s\n' "2048" > "$status_runtime_root_3/jobs/stopped-job/min-available-memory-mb"
printf '%s\n' "systemd-scope" > "$status_runtime_root_3/jobs/stopped-job/memory-enforcer"
cat > "$status_runtime_root_3/jobs/stopped-job/memory-exceeded" <<'EOF'
reason=host-available-memory-reserve
phase=watch
EOF
printf '%s\n' "memory-exceeded" > "$status_runtime_root_3/child-jobs/clasp-builder-20260314T123001Z/status"
printf '%s\n' "137" > "$status_runtime_root_3/child-jobs/clasp-builder-20260314T123001Z/exit-status"
printf '%s\n' "256" > "$status_runtime_root_3/child-jobs/clasp-builder-20260314T123001Z/memory-mb"
printf '%s\n' "1024" > "$status_runtime_root_3/child-jobs/clasp-builder-20260314T123001Z/min-available-memory-mb"
printf '%s\n' "systemd-scope" > "$status_runtime_root_3/child-jobs/clasp-builder-20260314T123001Z/memory-enforcer"
cat > "$status_runtime_root_3/child-jobs/clasp-builder-20260314T123001Z/memory-exceeded" <<'EOF'
reason=host-available-memory-reserve
phase=preflight
EOF
cat > "$status_runtime_root_3/lane.log" <<'EOF'
interrupted line 1
EOF
printf '%s\n' "$status_runtime_root_4/jobs/admission-job" > "$status_runtime_root_4/job"
printf '%s\n' "admission-lock-unavailable" > "$status_runtime_root_4/jobs/admission-job/status"
printf '%s\n' "125" > "$status_runtime_root_4/jobs/admission-job/exit-status"
cat > "$status_runtime_root_4/jobs/admission-job/admission-error" <<'EOF'
reason=admission-lock-open-failed
EOF
cat > "$status_runtime_root_4/lane.log" <<'EOF'
admission line 1
EOF
printf '%s\n' "$status_runtime_root_5/jobs/enforcer-job" > "$status_runtime_root_5/job"
printf '%s\n' "memory-enforcer-unavailable" > "$status_runtime_root_5/jobs/enforcer-job/status"
printf '%s\n' "125" > "$status_runtime_root_5/jobs/enforcer-job/exit-status"
cat > "$status_runtime_root_5/jobs/enforcer-job/memory-enforcer-error" <<'EOF'
reason=systemd-scope-required-unavailable
EOF
cat > "$status_runtime_root_5/lane.log" <<'EOF'
enforcer line 1
EOF
printf '%s\n' "$status_runtime_root_6/jobs/disk-job" > "$status_runtime_root_6/job"
printf '%s\n' "disk-exceeded" > "$status_runtime_root_6/jobs/disk-job/status"
printf '%s\n' "123" > "$status_runtime_root_6/jobs/disk-job/exit-status"
cat > "$status_runtime_root_6/jobs/disk-job/disk-exceeded" <<'EOF'
reason=host-available-disk-headroom
phase=watch
recovery_command=bash scripts/clasp-clean-generated-state.sh --health --json --include-run-binary-cache --include-temp-caches --include-build-caches --include-codex-logs
recovery_apply_command=bash scripts/clasp-clean-generated-state.sh --apply --include-run-binary-cache --include-temp-caches --include-build-caches --include-codex-logs
recovery_note=inspect the health report and run apply only when safeToClean is true
EOF
cat > "$status_runtime_root_6/lane.log" <<'EOF'
disk line 1
EOF

sleep 30 >/dev/null 2>&1 &
status_live_pid="$!"
mkdir -p "$status_runtime_root_1"
printf '%s\n' "$status_live_pid" > "$status_runtime_root_1/pid"
kill "$status_live_pid" >/dev/null 2>&1 || true
wait "$status_live_pid" 2>/dev/null || true

sleep 30 >/dev/null 2>&1 &
status_live_pid="$!"
mkdir -p "$status_runtime_root_2"
printf '%s\n' "$status_live_pid" > "$status_runtime_root_2/pid"

bash "$project_root/scripts/clasp-swarm-status.sh" "$status_wave_name" > "$status_text_output"
bash "$project_root/scripts/clasp-swarm-status.sh" --json "$status_wave_name" > "$status_json_output"

bash -lc "
  set -euo pipefail
  text=\$(cat '$status_text_output')
  [[ \"\$text\" == *'wave: $status_wave_name'* ]]
  [[ \"\$text\" == *'summary: lanes=6 running=1 stopped=5 completed=3 blocked=1'* ]]
  [[ \"\$text\" == *'run-states: admission-lock-unavailable=1 builder-complete=1 disk-exceeded=1 memory-enforcer-unavailable=1 memory-exceeded=1 pass=1'* ]]
  [[ \"\$text\" == *'lane: 01-active'* ]]
  [[ \"\$text\" == *'stale pid: '* ]]
  [[ \"\$text\" == *'current task: AA-100-sample'* ]]
  [[ \"\$text\" == *'latest run: 20260314T121500Z-AA-100-sample-attempt2'* ]]
  [[ \"\$text\" == *'run status: pass'* ]]
  [[ \"\$text\" == *'run summary: latest verifier summary'* ]]
  [[ \"\$text\" == *'lane: 02-idle'* ]]
  [[ \"\$text\" == *'pid: $status_live_pid'* ]]
  [[ \"\$text\" == *'latest child job: clasp-builder-20260314T122600Z'* ]]
  [[ \"\$text\" == *'child job status: started'* ]]
  [[ \"\$text\" == *'run status: builder-complete'* ]]
  [[ \"\$text\" == *'run summary: builder summary only'* ]]
  [[ \"\$text\" == *'lane: 03-interrupted'* ]]
  [[ \"\$text\" == *'managed job status: memory-exceeded'* ]]
  [[ \"\$text\" == *'managed job exit: 137'* ]]
  [[ \"\$text\" == *'managed job memory mb: 512'* ]]
  [[ \"\$text\" == *'managed job min available memory mb: 2048'* ]]
  [[ \"\$text\" == *'managed job memory enforcer: systemd-scope'* ]]
  [[ \"\$text\" == *'managed job memory exceeded: true'* ]]
  [[ \"\$text\" == *'managed job failure reason: host-available-memory-reserve'* ]]
  [[ \"\$text\" == *'managed job failure phase: watch'* ]]
  [[ \"\$text\" == *'latest child job: clasp-builder-20260314T123001Z'* ]]
  [[ \"\$text\" == *'child job status: memory-exceeded'* ]]
  [[ \"\$text\" == *'child job exit: 137'* ]]
  [[ \"\$text\" == *'child job memory mb: 256'* ]]
  [[ \"\$text\" == *'child job min available memory mb: 1024'* ]]
  [[ \"\$text\" == *'child job memory enforcer: systemd-scope'* ]]
  [[ \"\$text\" == *'child job memory exceeded: true'* ]]
  [[ \"\$text\" == *'child job failure reason: host-available-memory-reserve'* ]]
  [[ \"\$text\" == *'child job failure phase: preflight'* ]]
  [[ \"\$text\" == *'current task: CC-300-interrupted'* ]]
  [[ \"\$text\" == *'run status: memory-exceeded'* ]]
  [[ \"\$text\" == *'run summary: Lane 03-interrupted stopped before writing a structured report because the managed job exceeded its memory guard.'* ]]
  [[ \"\$text\" == *'lane: 04-admission'* ]]
  [[ \"\$text\" == *'managed job status: admission-lock-unavailable'* ]]
  [[ \"\$text\" == *'managed job admission error: true'* ]]
  [[ \"\$text\" == *'managed job failure reason: admission-lock-open-failed'* ]]
  [[ \"\$text\" == *'current task: DD-400-admission'* ]]
  [[ \"\$text\" == *'run status: admission-lock-unavailable'* ]]
  [[ \"\$text\" == *'run summary: Lane 04-admission stopped before writing a structured report because the managed-job admission lock was unavailable.'* ]]
  [[ \"\$text\" == *'lane: 05-enforcer'* ]]
  [[ \"\$text\" == *'managed job status: memory-enforcer-unavailable'* ]]
  [[ \"\$text\" == *'managed job memory enforcer error: true'* ]]
  [[ \"\$text\" == *'managed job failure reason: systemd-scope-required-unavailable'* ]]
  [[ \"\$text\" == *'current task: EE-500-enforcer'* ]]
  [[ \"\$text\" == *'run status: memory-enforcer-unavailable'* ]]
  [[ \"\$text\" == *'run summary: Lane 05-enforcer stopped before writing a structured report because the managed-job memory enforcer was unavailable.'* ]]
  [[ \"\$text\" == *'lane: 06-disk'* ]]
  [[ \"\$text\" == *'managed job status: disk-exceeded'* ]]
  [[ \"\$text\" == *'managed job disk exceeded: true'* ]]
  [[ \"\$text\" == *'managed job failure reason: host-available-disk-headroom'* ]]
  [[ \"\$text\" == *'managed job failure phase: watch'* ]]
  [[ \"\$text\" == *'managed job recovery command: bash scripts/clasp-clean-generated-state.sh --health --json --include-run-binary-cache --include-temp-caches --include-build-caches --include-codex-logs'* ]]
  [[ \"\$text\" == *'managed job recovery apply command: bash scripts/clasp-clean-generated-state.sh --apply --include-run-binary-cache --include-temp-caches --include-build-caches --include-codex-logs'* ]]
  [[ \"\$text\" == *'managed job recovery note: inspect the health report and run apply only when safeToClean is true'* ]]
  [[ \"\$text\" == *'current task: FF-600-disk'* ]]
  [[ \"\$text\" == *'run status: disk-exceeded'* ]]
  [[ \"\$text\" == *'run summary: Lane 06-disk stopped before writing a structured report because the managed job exceeded its disk guard.'* ]]
  [[ \"\$text\" == *'line 6'* ]]
  [[ \"\$text\" == *'idle line 2'* ]]
  node - <<'EOF' '$status_json_output' '$status_wave_name' '$status_live_pid'
const fs = require('fs');
const [jsonPath, expectedWave, livePid] = process.argv.slice(2);
const payload = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
if (payload.wave !== expectedWave) {
  throw new Error(\`unexpected wave: \${payload.wave}\`);
}
if (payload.summary.laneCount !== 6 || payload.summary.runningCount !== 1 || payload.summary.stoppedCount !== 5) {
  throw new Error('unexpected lane summary counts');
}
if (payload.summary.completedCount !== 3 || payload.summary.blockedCount !== 1) {
  throw new Error('unexpected completion summary counts');
}
if (
  payload.summary.runStateCounts?.pass !== 1 ||
  payload.summary.runStateCounts?.['builder-complete'] !== 1 ||
  payload.summary.runStateCounts?.['memory-exceeded'] !== 1 ||
  payload.summary.runStateCounts?.['disk-exceeded'] !== 1 ||
  payload.summary.runStateCounts?.['admission-lock-unavailable'] !== 1 ||
  payload.summary.runStateCounts?.['memory-enforcer-unavailable'] !== 1
) {
  throw new Error('unexpected run-state summary counts');
}
if (Object.keys(payload.summary.runStateCounts || {}).length !== 6) {
  throw new Error('unexpected run-state summary keys');
}
const active = payload.lanes.find((lane) => lane.lane === '01-active');
const idle = payload.lanes.find((lane) => lane.lane === '02-idle');
const interrupted = payload.lanes.find((lane) => lane.lane === '03-interrupted');
const admission = payload.lanes.find((lane) => lane.lane === '04-admission');
const enforcer = payload.lanes.find((lane) => lane.lane === '05-enforcer');
const disk = payload.lanes.find((lane) => lane.lane === '06-disk');
if (!active || !idle || !interrupted || !admission || !enforcer || !disk) {
  throw new Error('expected all lanes in JSON output');
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
if (!idle.latestChildJob || idle.latestChildJob.name !== 'clasp-builder-20260314T122600Z') {
  throw new Error('running lane should report newest child by start time, not lexical name order');
}
if (idle.latestChildJob.status !== 'started') {
  throw new Error('unexpected idle-lane latest child status');
}
if (idle.latestRun?.status !== 'builder-complete' || idle.latestRun?.summary !== 'builder summary only') {
  throw new Error('unexpected idle-lane run summary');
}
if (interrupted.status !== 'stopped' || interrupted.managedJobStatus !== 'memory-exceeded' || interrupted.managedJobExitStatus !== '137') {
  throw new Error('unexpected interrupted-lane job state');
}
if (interrupted.managedJobMemoryMb !== 512 || interrupted.managedJobMinAvailableMemoryMb !== 2048 || interrupted.managedJobMemoryEnforcer !== 'systemd-scope') {
  throw new Error('unexpected interrupted-lane memory guard state');
}
if (interrupted.managedJobMemoryExceeded !== true || interrupted.managedJobDiskExceeded !== false) {
  throw new Error('unexpected interrupted-lane managed guard markers');
}
if (interrupted.managedJobFailureReason !== 'host-available-memory-reserve' || interrupted.managedJobFailurePhase !== 'watch') {
  throw new Error('unexpected interrupted-lane managed failure detail');
}
if (!interrupted.latestChildJob || interrupted.latestChildJob.name !== 'clasp-builder-20260314T123001Z') {
  throw new Error('missing interrupted-lane child job state');
}
if (interrupted.latestChildJob.status !== 'memory-exceeded' || interrupted.latestChildJob.exitStatus !== '137') {
  throw new Error('unexpected interrupted-lane child job status');
}
if (interrupted.latestChildJob.memoryMb !== 256 || interrupted.latestChildJob.minAvailableMemoryMb !== 1024 || interrupted.latestChildJob.memoryEnforcer !== 'systemd-scope') {
  throw new Error('unexpected interrupted-lane child guard state');
}
if (interrupted.latestChildJob.memoryExceeded !== true || interrupted.latestChildJob.diskExceeded !== false) {
  throw new Error('unexpected interrupted-lane child guard markers');
}
if (interrupted.latestChildJob.failureReason !== 'host-available-memory-reserve' || interrupted.latestChildJob.failurePhase !== 'preflight') {
  throw new Error('unexpected interrupted-lane child failure detail');
}
if (interrupted.latestRun?.status !== 'memory-exceeded' || interrupted.latestRun?.summary !== 'Lane 03-interrupted stopped before writing a structured report because the managed job exceeded its memory guard.') {
  throw new Error('unexpected interrupted-lane run summary');
}
if (
  interrupted.recommendedAction?.type !== 'reduce-memory-pressure' ||
  interrupted.recommendedAction?.reason !== 'host-available-memory-reserve' ||
  interrupted.recommendedAction?.phase !== 'watch' ||
  interrupted.recommendedAction?.command !== null ||
  !interrupted.recommendedAction?.note?.includes('lower swarm concurrency')
) {
  throw new Error('unexpected interrupted-lane recommended action');
}
if (admission.status !== 'stopped' || admission.managedJobStatus !== 'admission-lock-unavailable' || admission.managedJobExitStatus !== '125') {
  throw new Error('unexpected admission-lane job state');
}
if (admission.managedJobAdmissionError !== true || admission.managedJobMemoryEnforcerError !== false) {
  throw new Error('unexpected admission-lane managed error markers');
}
if (admission.managedJobFailureReason !== 'admission-lock-open-failed') {
  throw new Error('unexpected admission-lane failure reason');
}
if (admission.latestRun?.status !== 'admission-lock-unavailable' || admission.latestRun?.summary !== 'Lane 04-admission stopped before writing a structured report because the managed-job admission lock was unavailable.') {
  throw new Error('unexpected admission-lane run summary');
}
if (
  admission.recommendedAction?.type !== 'repair-admission-lock' ||
  admission.recommendedAction?.reason !== 'admission-lock-open-failed' ||
  !admission.recommendedAction?.note?.includes('admission lock')
) {
  throw new Error('unexpected admission-lane recommended action');
}
if (enforcer.status !== 'stopped' || enforcer.managedJobStatus !== 'memory-enforcer-unavailable' || enforcer.managedJobExitStatus !== '125') {
  throw new Error('unexpected enforcer-lane job state');
}
if (enforcer.managedJobAdmissionError !== false || enforcer.managedJobMemoryEnforcerError !== true) {
  throw new Error('unexpected enforcer-lane managed error markers');
}
if (enforcer.managedJobFailureReason !== 'systemd-scope-required-unavailable') {
  throw new Error('unexpected enforcer-lane failure reason');
}
if (enforcer.latestRun?.status !== 'memory-enforcer-unavailable' || enforcer.latestRun?.summary !== 'Lane 05-enforcer stopped before writing a structured report because the managed-job memory enforcer was unavailable.') {
  throw new Error('unexpected enforcer-lane run summary');
}
if (
  enforcer.recommendedAction?.type !== 'repair-memory-enforcer' ||
  enforcer.recommendedAction?.reason !== 'systemd-scope-required-unavailable' ||
  !enforcer.recommendedAction?.note?.includes('memory enforcer')
) {
  throw new Error('unexpected enforcer-lane recommended action');
}
if (disk.status !== 'stopped' || disk.managedJobStatus !== 'disk-exceeded' || disk.managedJobExitStatus !== '123') {
  throw new Error('unexpected disk-lane job state');
}
if (disk.managedJobDiskExceeded !== true || disk.managedJobMemoryExceeded !== false) {
  throw new Error('unexpected disk-lane managed guard markers');
}
if (disk.managedJobFailureReason !== 'host-available-disk-headroom' || disk.managedJobFailurePhase !== 'watch') {
  throw new Error('unexpected disk-lane failure detail');
}
if (disk.managedJobRecoveryCommand !== 'bash scripts/clasp-clean-generated-state.sh --health --json --include-run-binary-cache --include-temp-caches --include-build-caches --include-codex-logs') {
  throw new Error('unexpected disk-lane recovery command');
}
if (disk.managedJobRecoveryApplyCommand !== 'bash scripts/clasp-clean-generated-state.sh --apply --include-run-binary-cache --include-temp-caches --include-build-caches --include-codex-logs') {
  throw new Error('unexpected disk-lane recovery apply command');
}
if (disk.managedJobRecoveryNote !== 'inspect the health report and run apply only when safeToClean is true') {
  throw new Error('unexpected disk-lane recovery note');
}
if (disk.latestRun?.status !== 'disk-exceeded' || disk.latestRun?.summary !== 'Lane 06-disk stopped before writing a structured report because the managed job exceeded its disk guard.') {
  throw new Error('unexpected disk-lane run summary');
}
if (
  disk.recommendedAction?.type !== 'recover-disk' ||
  disk.recommendedAction?.reason !== 'host-available-disk-headroom' ||
  disk.recommendedAction?.phase !== 'watch' ||
  disk.recommendedAction?.command !== 'bash scripts/clasp-clean-generated-state.sh --health --json --include-run-binary-cache --include-temp-caches --include-build-caches --include-codex-logs' ||
  disk.recommendedAction?.applyCommand !== 'bash scripts/clasp-clean-generated-state.sh --apply --include-run-binary-cache --include-temp-caches --include-build-caches --include-codex-logs' ||
  disk.recommendedAction?.note !== 'inspect the health report and run apply only when safeToClean is true'
) {
  throw new Error('unexpected disk-lane recommended action');
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

stop_child_wave_name="stop-child-test-$$"
stop_child_lane_root="$project_root/agents/swarm/$stop_child_wave_name/01-child"
stop_child_runtime_root="$project_root/.clasp-swarm/$stop_child_wave_name/01-child"
mkdir -p "$stop_child_lane_root" "$stop_child_runtime_root/child-jobs"

cat > "$stop_child_lane_root/SC-001-child-stop.md" <<'EOF'
# SC-001 Child Stop

## Goal

Exercise exact managed-child stop behavior for orphaned child jobs.
EOF

stop_child_job="$(
  CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE=never \
  CLASP_MANAGED_JOB_DEFAULT_MIN_AVAILABLE_MEMORY_MB=0 \
    "$project_root/scripts/run-managed-job.sh" \
      --jobs-root "$stop_child_runtime_root/child-jobs" \
      --job-id orphan-child \
      --memory-mb 64 \
      --min-available-memory-mb 1 \
      -- bash -c 'while true; do sleep 1; done'
)"

bash -lc "
  set -euo pipefail
  deadline=\$((SECONDS + 5))
  while [[ ! -f '$stop_child_job/pid' ]]; do
    if (( SECONDS >= deadline )); then
      echo 'timed out waiting for orphan child managed job' >&2
      exit 1
    fi
    sleep 0.05
  done
  child_pid=\$(tr -d '[:space:]' < '$stop_child_job/pid')
  [[ \$(sed -n '1p' '$stop_child_job/status') == 'started' ]]
  kill -0 \"\$child_pid\" >/dev/null 2>&1

  output=\$(CLASP_MANAGED_JOB_STOP_TIMEOUT_SECS=10 CLASP_MANAGED_JOB_KILL_AFTER_SECS=1 bash '$project_root/scripts/clasp-swarm-stop.sh' '$stop_child_wave_name')
  [[ \"\$output\" == *'stopped lane=01-child child=orphan-child pid='* ]]
  [[ \"\$output\" == *'lane 01-child is not running'* ]]
  [[ \$(sed -n '1p' '$stop_child_job/status') == 'stopped' ]]
  [[ -f '$stop_child_job/exit-status' ]]

  deadline=\$((SECONDS + 5))
  while kill -0 \"\$child_pid\" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      echo \"orphan child managed job survived stop: \$child_pid\" >&2
      exit 1
    fi
    sleep 0.05
  done
" >/dev/null

summary_wave_name="summary-test-$$"
summary_lane_root_1="$project_root/agents/swarm/$summary_wave_name/01-core"
summary_lane_root_2="$project_root/agents/swarm/$summary_wave_name/02-language"
summary_runtime_root_1="$project_root/.clasp-swarm/$summary_wave_name/01-core"
summary_runtime_root_2="$project_root/.clasp-swarm/$summary_wave_name/02-language"
summary_text_output="$(mktemp)"
summary_json_output="$(mktemp)"
summary_markdown_output="$(mktemp)"

mkdir -p \
  "$summary_lane_root_1" \
  "$summary_lane_root_2" \
  "$summary_runtime_root_1/runs/20260314T120000Z-SW-001-first-attempt1" \
  "$summary_runtime_root_1/runs/20260314T130000Z-SW-002-second-attempt1" \
  "$summary_runtime_root_2/runs/20260314T140000Z-LG-001-third-attempt1" \
  "$summary_runtime_root_2/runs/20260314T150000Z-LG-002-fourth-attempt1"

cat > "$summary_runtime_root_1/runs/20260314T120000Z-SW-001-first-attempt1/verifier-report.json" <<'EOF'
{
  "verdict": "pass",
  "summary": "swarm task passed",
  "findings": [],
  "tests_run": [],
  "follow_up": []
}
EOF
TZ=UTC touch -t 202603141210 "$summary_runtime_root_1/runs/20260314T120000Z-SW-001-first-attempt1/verifier-report.json"

cat > "$summary_runtime_root_1/runs/20260314T130000Z-SW-002-second-attempt1/verifier-report.json" <<'EOF'
{
  "verdict": "fail",
  "summary": "builder timed out",
  "findings": [
    "builder exited with code 124 while processing SW-002-second."
  ],
  "tests_run": [],
  "follow_up": []
}
EOF
TZ=UTC touch -t 202603141320 "$summary_runtime_root_1/runs/20260314T130000Z-SW-002-second-attempt1/verifier-report.json"

cat > "$summary_runtime_root_2/runs/20260314T140000Z-LG-001-third-attempt1/verifier-report.json" <<'EOF'
{
  "verdict": "fail",
  "summary": "semantic check failed",
  "findings": [
    "type mismatch remains"
  ],
  "tests_run": [],
  "follow_up": []
}
EOF
TZ=UTC touch -t 202603141405 "$summary_runtime_root_2/runs/20260314T140000Z-LG-001-third-attempt1/verifier-report.json"

cat > "$summary_runtime_root_2/runs/20260314T150000Z-LG-002-fourth-attempt1/builder-report.json" <<'EOF'
{
  "summary": "builder finished",
  "files_touched": [],
  "tests_run": [],
  "residual_risks": []
}
EOF
TZ=UTC touch -t 202603141502 "$summary_runtime_root_2/runs/20260314T150000Z-LG-002-fourth-attempt1/builder-report.json"

bash "$project_root/scripts/clasp-swarm-summary.sh" "$summary_wave_name" > "$summary_text_output"
bash "$project_root/scripts/clasp-swarm-summary.sh" --json "$summary_wave_name" > "$summary_json_output"
bash "$project_root/scripts/clasp-swarm-summary.sh" --markdown "$summary_wave_name" > "$summary_markdown_output"

bash -lc "
  set -euo pipefail
  text=\$(cat '$summary_text_output')
  markdown=\$(cat '$summary_markdown_output')
  [[ \"\$text\" == *'wave: $summary_wave_name'* ]]
  [[ \"\$text\" == *'summary: runs=4 completed=3 incomplete=1 pass-rate=33.3% timeout-rate=33.3% mean-time=700.0s'* ]]
  [[ \"\$text\" == *'family: LG runs=2 completed=1 incomplete=1 pass-rate=0.0% timeout-rate=0.0% mean-time=300.0s'* ]]
  [[ \"\$text\" == *'family: SW runs=2 completed=2 incomplete=0 pass-rate=50.0% timeout-rate=50.0% mean-time=900.0s'* ]]
  [[ \"\$markdown\" == *'# Swarm Summary: $summary_wave_name'* ]]
  [[ \"\$markdown\" == *'| scope | runs | completed | incomplete | pass rate | timeout rate | mean time |'* ]]
  [[ \"\$markdown\" == *'| overall | 4 | 3 | 1 | 33.3% | 33.3% | 700.0s |'* ]]
  [[ \"\$markdown\" == *'| LG | 2 | 1 | 1 | 0.0% | 0.0% | 300.0s |'* ]]
  [[ \"\$markdown\" == *'| SW | 2 | 2 | 0 | 50.0% | 50.0% | 900.0s |'* ]]
  node - <<'EOF' '$summary_json_output' '$summary_wave_name'
const fs = require('fs');
const [jsonPath, expectedWave] = process.argv.slice(2);
const payload = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
if (payload.wave !== expectedWave) {
  throw new Error(\`unexpected wave: \${payload.wave}\`);
}
if (payload.summary.totalRuns !== 4 || payload.summary.completedRuns !== 3 || payload.summary.incompleteRuns !== 1) {
  throw new Error('unexpected overall run counts');
}
if (Math.abs(payload.summary.passRate - (1 / 3)) > 1e-9) {
  throw new Error('unexpected overall pass rate');
}
if (Math.abs(payload.summary.timeoutRate - (1 / 3)) > 1e-9) {
  throw new Error('unexpected overall timeout rate');
}
if (Math.abs(payload.summary.meanTimeSeconds - 700) > 1e-9) {
  throw new Error('unexpected overall mean time');
}
const lg = payload.families.find((family) => family.taskFamily === 'LG');
const sw = payload.families.find((family) => family.taskFamily === 'SW');
if (!lg || !sw) {
  throw new Error('expected LG and SW families');
}
if (lg.totalRuns !== 2 || lg.completedRuns !== 1 || lg.incompleteRuns !== 1) {
  throw new Error('unexpected LG counts');
}
if (Math.abs(lg.meanTimeSeconds - 300) > 1e-9 || lg.timeoutRate !== 0 || lg.passRate !== 0) {
  throw new Error('unexpected LG metrics');
}
if (sw.totalRuns !== 2 || sw.completedRuns !== 2 || sw.incompleteRuns !== 0) {
  throw new Error('unexpected SW counts');
}
if (Math.abs(sw.passRate - 0.5) > 1e-9 || Math.abs(sw.timeoutRate - 0.5) > 1e-9) {
  throw new Error('unexpected SW rates');
}
if (Math.abs(sw.meanTimeSeconds - 900) > 1e-9) {
  throw new Error('unexpected SW mean time');
}
EOF
" >/dev/null

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

cat > "$lane_root/ZZ-004-batched-follow-up.md" <<'EOF'
# ZZ-004 Batched follow up

## Goal

Wait for the full foundation batch to finish.

## Why

This task proves dependency labels wait for every task in the batch.

## Scope

- Wait for the foundation label

## Likely Files

- `src/batched-follow-up`

## Dependencies

- None

## Dependency Labels

- foundation

## Acceptance

- done

## Verification

```sh
bash scripts/verify-all.sh
```
EOF

cat > "$lane_root/ZZ-005-foundation-a.md" <<'EOF'
# ZZ-005 Foundation a

## Goal

Contribute to the shared foundation batch.

## Why

This task proves batch completion waits for every batched task.

## Scope

- Complete the foundation batch

## Likely Files

- `src/foundation-a`

## Batch

foundation

## Dependencies

- None

## Acceptance

- done

## Verification

```sh
bash scripts/verify-all.sh
```
EOF

cat > "$lane_root/ZZ-006-foundation-b.md" <<'EOF'
# ZZ-006 Foundation b

## Goal

Finish the second task in the shared foundation batch.

## Why

This task proves batch labels only clear after every member completes.

## Scope

- Complete the foundation batch

## Likely Files

- `src/foundation-b`

## Batch

foundation

## Dependencies

- None

## Acceptance

- done

## Verification

```sh
bash scripts/verify-all.sh
```
EOF

cat > "$lane_root/LG-001-already-complete.md" <<'EOF'
# LG-001 Already complete

## Goal

Prove the swarm skips tasks already recorded as complete.

## Why

Ready-task selection should not repeat work that already has a durable completion marker.

## Scope

- Skip already-complete tasks during ready-task selection

## Likely Files

- `scripts/clasp-swarm-common.sh`

## Dependencies

- None

## Acceptance

- done

## Verification

```sh
bash scripts/verify-all.sh
```
EOF

printf '%s\t%s\n' '2026-03-13T00:00:00Z' 'landed' > "$global_completed_root/LG-001"

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

  batch_only=\$(clasp_swarm_select_next_ready_task '$lane_root' '$completed_root' '$global_completed_root' '$blocked_root' foundation)
  [[ \$(basename \"\$batch_only\") == 'ZZ-005-foundation-a.md' ]]

  ! clasp_swarm_batch_is_complete foundation '$lane_root' '$global_completed_root'
  ! clasp_swarm_task_dependencies_met '$lane_root/ZZ-004-batched-follow-up.md' '$lane_root' '$global_completed_root'

  printf '%s\t%s\n' '2026-03-13T00:00:02Z' 'c0ffee' > '$global_completed_root/ZZ-005'
  ! clasp_swarm_batch_is_complete foundation '$lane_root' '$global_completed_root'
  ! clasp_swarm_task_dependencies_met '$lane_root/ZZ-004-batched-follow-up.md' '$lane_root' '$global_completed_root'

  printf '%s\t%s\n' '2026-03-13T00:00:03Z' 'faded' > '$global_completed_root/ZZ-006'
  clasp_swarm_batch_is_complete foundation '$lane_root' '$global_completed_root'
  clasp_swarm_task_dependencies_met '$lane_root/ZZ-004-batched-follow-up.md' '$lane_root' '$global_completed_root'
" >/dev/null

task_file_drain_test_root="$(mktemp -d)"
task_file_drain_lane_root="$task_file_drain_test_root/lane"
task_file_drain_completed_root="$task_file_drain_test_root/completed"
task_file_drain_global_completed_root="$task_file_drain_test_root/global-completed"
task_file_drain_blocked_root="$task_file_drain_test_root/blocked"
task_file_drain_stderr="$task_file_drain_test_root/stderr.log"

mkdir -p \
  "$task_file_drain_lane_root" \
  "$task_file_drain_completed_root" \
  "$task_file_drain_global_completed_root" \
  "$task_file_drain_blocked_root"

write_task_manifest \
  "$task_file_drain_lane_root/RC-001-ready-now.md" \
  "RC-001 Ready now"

for task_number in $(seq 2 60); do
  task_key="$(printf 'RC-%03d' "$task_number")"
  write_task_manifest \
    "$task_file_drain_lane_root/$task_key-waits.md" \
    "$task_key Waits" \
    "ZZ-999"
done

bash -lc "
  set -euo pipefail
  source '$project_root/scripts/clasp-swarm-common.sh'
  next=\$(clasp_swarm_select_next_ready_task '$task_file_drain_lane_root' '$task_file_drain_completed_root' '$task_file_drain_global_completed_root' '$task_file_drain_blocked_root')
  [[ \$(basename \"\$next\") == 'RC-001-ready-now.md' ]]
  rm -rf '$task_file_drain_lane_root'
  sleep 0.2
" 2>"$task_file_drain_stderr" >/dev/null

if [[ -s "$task_file_drain_stderr" ]]; then
  cat "$task_file_drain_stderr" >&2
  exit 1
fi

invalid_lane_root="$(mktemp -d)"

cat > "$invalid_lane_root/ZZ-004-invalid-manifest.md" <<'EOF'
# ZZ-004

## Goal

Missing title and the required structured sections.
EOF

trap - ERR
set +e
invalid_output="$(bash "$project_root/scripts/clasp-swarm-lane.sh" --list-tasks "$invalid_lane_root" 2>&1)"
invalid_status="$?"
set -e
trap 'report_test_failure "$LINENO" "$BASH_COMMAND"' ERR

if [[ "$invalid_status" -eq 0 ]]; then
  echo "expected invalid manifest listing to fail" >&2
  exit 1
fi

if [[ "$invalid_output" != *"manifest.title must be a non-empty string"* ]]; then
  echo "expected invalid manifest error to mention title validation" >&2
  printf '%s\n' "$invalid_output" >&2
  exit 1
fi

batch_start_test_root="$(mktemp -d)"
batch_start_project_root="$(make_batch_start_test_project "$batch_start_test_root")"

bash -lc "
  set -euo pipefail
  cd '$batch_start_project_root'

  batches=\$(bash scripts/clasp-swarm-start.sh --list-batches test-wave)
  [[ \"\$batches\" == *'foundation'* ]]

  output=\$(CLASP_SWARM_ALLOW_DIRTY=1 CLASP_SWARM_MAX_RUNNING_LANES=2 CLASP_SWARM_LANE_MEMORY_MB=1024 CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=1 CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 bash scripts/clasp-swarm-start.sh --batch foundation test-wave)
  [[ \"\$output\" == *'batch=foundation'* ]]
  [[ \"\$output\" == *'lane=01-foundation-a'* ]]
  [[ \"\$output\" == *'lane=02-foundation-b'* ]]
  [[ \"\$output\" != *'lane=03-follow-up'* ]]

  deadline=\$((SECONDS + \${CLASP_SWARM_TEST_LANE_WAIT_SECS:-60}))
  while [[ -f .clasp-swarm/test-wave/01-foundation-a/pid || -f .clasp-swarm/test-wave/02-foundation-b/pid ]]; do
    if (( SECONDS >= deadline )); then
      echo 'timed out waiting for foundation batch lanes to finish' >&2
      exit 1
    fi
    sleep 0.2
  done

  [[ -f BA-001-foundation-a.txt ]]
  [[ -f BA-002-foundation-b.txt ]]
  [[ ! -f BA-003-follow-up.txt ]]
  [[ \$(sort builder-events.log | tr '\n' ' ') == 'BA-001-foundation-a BA-002-foundation-b ' ]]

  CLASP_SWARM_ALLOW_DIRTY=1 CLASP_SWARM_LANE_MEMORY_MB=1024 CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=1 CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 bash scripts/clasp-swarm-start.sh test-wave >/dev/null
  deadline=\$((SECONDS + \${CLASP_SWARM_TEST_LANE_WAIT_SECS:-60}))
  while [[ -f .clasp-swarm/test-wave/03-follow-up/pid ]]; do
    if (( SECONDS >= deadline )); then
      echo 'timed out waiting for follow-up lane to finish' >&2
      exit 1
    fi
    sleep 0.2
  done

  [[ -f BA-003-follow-up.txt ]]
" >/dev/null

swarm_resource_cap_test_root="$(mktemp -d)"
swarm_resource_cap_project_root="$(make_batch_start_test_project "$swarm_resource_cap_test_root")"

bash -lc "
  set -euo pipefail
  cd '$swarm_resource_cap_project_root'

  output=\$(CLASP_SWARM_ALLOW_DIRTY=1 CLASP_SWARM_MAX_RUNNING_LANES=1 CLASP_SWARM_LANE_MEMORY_MB=1024 CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=1 CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 CLASP_SWARM_TEST_BUILDER_SLEEP_SECS=2 bash scripts/clasp-swarm-start.sh --batch foundation test-wave)
  [[ \"\$output\" == *'started lane=01-foundation-a'* ]]
  [[ \"\$output\" == *'resource guard: not starting lane=02-foundation-b; running_lanes=1 max_running_lanes=1'* ]]
  [[ ! -f .clasp-swarm/test-wave/02-foundation-b/job ]]

  first_job=\$(sed -n '1p' .clasp-swarm/test-wave/01-foundation-a/job)
  [[ \$(cat \"\$first_job/memory-mb\") == '1024' ]]

  deadline=\$((SECONDS + \${CLASP_SWARM_TEST_LANE_WAIT_SECS:-60}))
  while [[ -f .clasp-swarm/test-wave/01-foundation-a/pid ]]; do
    if (( SECONDS >= deadline )); then
      echo 'timed out waiting for capped foundation lane to finish' >&2
      exit 1
    fi
    sleep 0.2
  done

  output=\$(CLASP_SWARM_ALLOW_DIRTY=1 CLASP_SWARM_MAX_RUNNING_LANES=1 CLASP_SWARM_LANE_MEMORY_MB=1024 CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=1 CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 bash scripts/clasp-swarm-start.sh --batch foundation test-wave)
  [[ \"\$output\" == *'started lane=02-foundation-b'* ]]

  deadline=\$((SECONDS + \${CLASP_SWARM_TEST_LANE_WAIT_SECS:-60}))
  while [[ -f .clasp-swarm/test-wave/02-foundation-b/pid ]]; do
    if (( SECONDS >= deadline )); then
      echo 'timed out waiting for second capped foundation lane to finish' >&2
      exit 1
    fi
    sleep 0.2
  done

  [[ -f BA-001-foundation-a.txt ]]
  [[ -f BA-002-foundation-b.txt ]]
  grep -F 'BA-001-foundation-a CLASP_NATIVE_JOBS_MAX=1' builder-env.log >/dev/null
  grep -F 'BA-002-foundation-b CLASP_NATIVE_JOBS_MAX=1' builder-env.log >/dev/null
" >/dev/null

swarm_memory_guard_test_root="$(mktemp -d)"
swarm_memory_guard_project_root="$(make_batch_start_test_project "$swarm_memory_guard_test_root")"

bash -lc "
  set -euo pipefail
  cd '$swarm_memory_guard_project_root'

  set +e
  invalid_output=\$(CLASP_SWARM_ALLOW_DIRTY=1 CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 CLASP_SWARM_MAX_RUNNING_LANES=not-a-number bash scripts/clasp-swarm-start.sh --batch foundation test-wave 2>&1)
  invalid_status=\$?
  set -e
  [[ \"\$invalid_status\" -ne 0 ]]
  [[ \"\$invalid_output\" == *'CLASP_SWARM_MAX_RUNNING_LANES must be a non-negative integer'* ]]

  output=\$(CLASP_SWARM_ALLOW_DIRTY=1 CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=999999999 bash scripts/clasp-swarm-start.sh --batch foundation test-wave)
  [[ \"\$output\" == *'resource guard: not starting lane=01-foundation-a; available_memory_mb='* ]]
  [[ \"\$output\" == *'min_available_memory_mb=999999999'* ]]
  [[ ! -f .clasp-swarm/test-wave/01-foundation-a/job ]]
  [[ ! -f .clasp-swarm/test-wave/02-foundation-b/job ]]
  [[ ! -f builder-events.log ]]

  output=\$(CLASP_SWARM_ALLOW_DIRTY=1 CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=0 CLASP_SWARM_LANE_MEMORY_MB=999999999 bash scripts/clasp-swarm-start.sh --batch foundation test-wave)
  [[ \"\$output\" == *'resource guard: not starting lane=01-foundation-a; available_memory_mb='* ]]
  [[ \"\$output\" == *'required_available_memory_mb=999999999'* ]]
  [[ \"\$output\" == *'lane_memory_mb=999999999'* ]]
  [[ ! -f .clasp-swarm/test-wave/01-foundation-a/job ]]
  [[ ! -f .clasp-swarm/test-wave/02-foundation-b/job ]]
  [[ ! -f builder-events.log ]]

	  output=\$(CLASP_SWARM_ALLOW_DIRTY=1 CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=0 CLASP_SWARM_LANE_MEMORY_MB=0 CLASP_SWARM_MIN_AVAILABLE_DISK_MB=999999999 bash scripts/clasp-swarm-start.sh --batch foundation test-wave)
	  [[ \"\$output\" == *'resource guard: not starting lane=01-foundation-a; available_disk_mb='* ]]
	  [[ \"\$output\" == *'min_available_disk_mb=999999999'* ]]
	  [[ ! -f .clasp-swarm/test-wave/01-foundation-a/job ]]
	  [[ ! -f .clasp-swarm/test-wave/02-foundation-b/job ]]
	  [[ ! -f builder-events.log ]]

	  output=\$(CLASP_SWARM_ALLOW_DIRTY=1 CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=0 CLASP_SWARM_LANE_MEMORY_MB=0 CLASP_SWARM_MIN_AVAILABLE_DISK_MB=1 CLASP_SWARM_MIN_DISK_HEADROOM_MB=999999999 bash scripts/clasp-swarm-start.sh --batch foundation test-wave)
	  [[ \"\$output\" == *'resource guard: not starting lane=01-foundation-a; available_disk_mb='* ]]
	  [[ \"\$output\" == *'disk_headroom_mb='* ]]
	  [[ \"\$output\" == *'min_disk_headroom_mb=999999999'* ]]
	  [[ ! -f .clasp-swarm/test-wave/01-foundation-a/job ]]
	  [[ ! -f .clasp-swarm/test-wave/02-foundation-b/job ]]
	  [[ ! -f builder-events.log ]]
	" >/dev/null

swarm_managed_admission_test_root="$(mktemp -d)"
swarm_managed_admission_project_root="$(make_batch_start_test_project "$swarm_managed_admission_test_root")"

bash -lc "
  set -euo pipefail
  cd '$swarm_managed_admission_project_root'

  holder_job_a=\$(CLASP_MANAGED_JOB_MAX_MEMORY_MB=0 CLASP_MANAGED_JOB_DEFAULT_MIN_AVAILABLE_MEMORY_MB=0 CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE=never CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root scripts/run-managed-job.sh --jobs-root \"\$PWD/.clasp-swarm/test-wave/01-foundation-a/jobs\" --job-id budget-holder-a --memory-mb 999999999 -- bash -c 'while true; do sleep 1; done')
  holder_job_b=\$(CLASP_MANAGED_JOB_MAX_MEMORY_MB=0 CLASP_MANAGED_JOB_DEFAULT_MIN_AVAILABLE_MEMORY_MB=0 CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE=never CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root scripts/run-managed-job.sh --jobs-root \"\$PWD/.clasp-swarm/test-wave/02-foundation-b/jobs\" --job-id budget-holder-b --memory-mb 999999999 -- bash -c 'while true; do sleep 1; done')
  trap 'scripts/stop-managed-job.sh --jobs-root \"\$PWD/.clasp-swarm/test-wave/01-foundation-a/jobs\" budget-holder-a >/dev/null 2>&1 || true; scripts/stop-managed-job.sh --jobs-root \"\$PWD/.clasp-swarm/test-wave/02-foundation-b/jobs\" budget-holder-b >/dev/null 2>&1 || true' EXIT
  for holder_job in \"\$holder_job_a\" \"\$holder_job_b\"; do
    deadline=\$((SECONDS + 5))
    while [[ ! -f \"\$holder_job/pid\" ]]; do
      if (( SECONDS >= deadline )); then
        echo 'timed out waiting for budget holder to start' >&2
        exit 1
      fi
      sleep 0.05
    done
    holder_status=\$(sed -n '1p' \"\$holder_job/status\")
    [[ \"\$holder_status\" == 'started' ]]
  done

  output=\$(CLASP_MANAGED_JOB_MAX_MEMORY_MB=0 CLASP_SWARM_ALLOW_DIRTY=1 CLASP_SWARM_MAX_RUNNING_LANES=2 CLASP_SWARM_LANE_MEMORY_MB=1 CLASP_SWARM_MIN_AVAILABLE_MEMORY_MB=1 CLASP_SWARM_MIN_AVAILABLE_DISK_MB=0 CLASP_SWARM_MIN_DISK_HEADROOM_MB=0 CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root bash scripts/clasp-swarm-start.sh --batch foundation test-wave 2>&1)
  [[ \"\$output\" == *'resource guard: not starting lane=01-foundation-a; managed_job_status=memory-exceeded'* ]]
  [[ \"\$output\" == *'lane=01-foundation-a memory-exceeded:'* ]]
  [[ \"\$output\" == *'running_managed_memory_budget_mb=999999999'* ]]
  [[ ! -f .clasp-swarm/test-wave/01-foundation-a/job ]]
  [[ ! -f .clasp-swarm/test-wave/01-foundation-a/pid ]]
  [[ ! -f .clasp-swarm/test-wave/02-foundation-b/job ]]
  [[ ! -f .clasp-swarm/test-wave/02-foundation-b/pid ]]
  [[ ! -f builder-events.log ]]
	" >/dev/null

swarm_child_admission_test_root="$(mktemp -d)"
swarm_child_admission_project_root="$(make_batch_start_test_project "$swarm_child_admission_test_root")"

bash -lc "
  set -euo pipefail
  cd '$swarm_child_admission_project_root'

  holder_job=\$(CLASP_MANAGED_JOB_MAX_MEMORY_MB=0 CLASP_MANAGED_JOB_DEFAULT_MIN_AVAILABLE_MEMORY_MB=0 CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE=never CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root scripts/run-managed-job.sh --jobs-root \"\$PWD/.clasp-swarm/test-wave/01-foundation-a/child-jobs\" --job-id child-budget-holder --memory-mb 999999999 -- bash -c 'while true; do sleep 1; done')
  trap 'scripts/stop-managed-job.sh --jobs-root \"\$PWD/.clasp-swarm/test-wave/01-foundation-a/child-jobs\" child-budget-holder >/dev/null 2>&1 || true' EXIT
  deadline=\$((SECONDS + 5))
  while [[ ! -f \"\$holder_job/pid\" ]]; do
    if (( SECONDS >= deadline )); then
      echo 'timed out waiting for child budget holder to start' >&2
      exit 1
    fi
    sleep 0.05
  done
  [[ \$(sed -n '1p' \"\$holder_job/status\") == 'started' ]]

  set +e
  output=\$(CLASP_MANAGED_JOB_MAX_MEMORY_MB=0 CLASP_SWARM_RETRY_LIMIT=3 CLASP_SWARM_CHILD_MEMORY_MB=1 CLASP_SWARM_CHILD_MIN_AVAILABLE_MEMORY_MB=1 CLASP_SWARM_CHILD_MIN_AVAILABLE_DISK_MB=0 CLASP_SWARM_CHILD_MIN_DISK_HEADROOM_MB=0 CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root bash scripts/clasp-swarm-lane.sh agents/swarm/test-wave/01-foundation-a 2>&1)
  lane_status=\$?
  set -e
  [[ \"\$lane_status\" -eq 0 ]]
  [[ \"\$output\" == *'lane subprocess clasp-builder managed job failed: status=memory-exceeded'* ]]
  [[ \"\$output\" == *'subprocess=clasp-builder memory-exceeded:'* ]]
  [[ \"\$output\" == *'running_managed_memory_budget_mb=999999999'* ]]
  [[ \"\$output\" == *'blocked on BA-001-foundation-a after builder resource guard: status=memory-exceeded'* ]]
  [[ ! -f builder-events.log ]]
  verifier_report=\$(find .clasp-swarm/test-wave/01-foundation-a/runs -name verifier-report.json -print | sort | tail -1)
  [[ -n \"\$verifier_report\" ]]
  grep -F 'Builder managed job hit the memory resource guard before the task could be verified.' \"\$verifier_report\" >/dev/null
  grep -F 'resource-guard-reason=host-available-memory-reserve' \"\$verifier_report\" >/dev/null
  grep -F 'Stop only managed jobs by metadata; do not kill unmanaged agent or operator sessions.' \"\$verifier_report\" >/dev/null
  [[ -f .clasp-swarm/test-wave/01-foundation-a/blocked/BA-001-foundation-a.json ]]
  child_job=\$(find .clasp-swarm/test-wave/01-foundation-a/child-jobs -mindepth 1 -maxdepth 1 -type d ! -name child-budget-holder -print | sort | tail -1)
  [[ -n \"\$child_job\" ]]
  [[ \$(find .clasp-swarm/test-wave/01-foundation-a/child-jobs -mindepth 1 -maxdepth 1 -type d ! -name child-budget-holder | wc -l | tr -d '[:space:]') == '1' ]]
  [[ \$(sed -n '1p' \"\$child_job/status\") == 'memory-exceeded' ]]
  [[ -f \"\$child_job/memory-exceeded\" ]]
	" >/dev/null

swarm_child_retryable_admission_test_root="$(mktemp -d)"
swarm_child_retryable_admission_project_root="$(make_batch_start_test_project "$swarm_child_retryable_admission_test_root")"

bash -lc "
  set -euo pipefail
  cd '$swarm_child_retryable_admission_project_root'

  holder_job=\$(CLASP_MANAGED_JOB_MAX_MEMORY_MB=0 CLASP_MANAGED_JOB_DEFAULT_MIN_AVAILABLE_MEMORY_MB=0 CLASP_MANAGED_JOB_USE_SYSTEMD_SCOPE=never CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root scripts/run-managed-job.sh --jobs-root \"\$PWD/.clasp-swarm/test-wave/01-foundation-a/child-jobs\" --job-id child-budget-holder --memory-mb 999999999 -- bash -c 'while true; do sleep 1; done')
  trap 'scripts/stop-managed-job.sh --jobs-root \"\$PWD/.clasp-swarm/test-wave/01-foundation-a/child-jobs\" child-budget-holder >/dev/null 2>&1 || true' EXIT
  deadline=\$((SECONDS + 5))
  while [[ ! -f \"\$holder_job/pid\" ]]; do
    if (( SECONDS >= deadline )); then
      echo 'timed out waiting for retryable child budget holder to start' >&2
      exit 1
    fi
    sleep 0.05
  done
  [[ \$(sed -n '1p' \"\$holder_job/status\") == 'started' ]]

  set +e
  output=\$(CLASP_MANAGED_JOB_MAX_MEMORY_MB=0 CLASP_SWARM_RETRY_LIMIT=3 CLASP_SWARM_RESOURCE_GUARD_BLOCK_MODE=retryable CLASP_SWARM_CHILD_MEMORY_MB=1 CLASP_SWARM_CHILD_MIN_AVAILABLE_MEMORY_MB=1 CLASP_SWARM_CHILD_MIN_AVAILABLE_DISK_MB=0 CLASP_SWARM_CHILD_MIN_DISK_HEADROOM_MB=0 CLASP_MANAGED_JOB_MEMORY_BUDGET_SCOPE=current-root bash scripts/clasp-swarm-lane.sh agents/swarm/test-wave/01-foundation-a 2>&1)
  lane_status=\$?
  set -e
  [[ \"\$lane_status\" -eq 0 ]]
  [[ \"\$output\" == *'lane subprocess clasp-builder managed job failed: status=memory-exceeded'* ]]
  [[ \"\$output\" == *'deferred retry for BA-001-foundation-a after builder resource guard: status=memory-exceeded mode=retryable'* ]]
  [[ ! -f builder-events.log ]]
  verifier_report=\$(find .clasp-swarm/test-wave/01-foundation-a/runs -name verifier-report.json -print | sort | tail -1)
  [[ -n \"\$verifier_report\" ]]
  grep -F 'Builder managed job hit the memory resource guard before the task could be verified.' \"\$verifier_report\" >/dev/null
  [[ ! -f .clasp-swarm/test-wave/01-foundation-a/blocked/BA-001-foundation-a.json ]]
  child_job=\$(find .clasp-swarm/test-wave/01-foundation-a/child-jobs -mindepth 1 -maxdepth 1 -type d ! -name child-budget-holder -print | sort | tail -1)
  [[ -n \"\$child_job\" ]]
  [[ \$(sed -n '1p' \"\$child_job/status\") == 'memory-exceeded' ]]
  [[ -f \"\$child_job/memory-exceeded\" ]]
	" >/dev/null

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

mkdir -p "$prompt_project_root/previous-run"
cat > "$prompt_project_root/previous-run/verifier-report.json" <<'EOF'
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
cat > "$prompt_project_root/previous-run/builder-report.json" <<'EOF'
{
  "summary": "Previous builder touched $(printf builder-summary) literally.",
  "files_touched": [
    "src/Compiler/Retry.clasp",
    "scripts/test-retry-context.sh"
  ],
  "tests_run": [
    "bash scripts/test-retry-context.sh"
  ],
  "residual_risks": [
    "The previous diff may need rebasing before reuse."
  ]
}
EOF
cat > "$prompt_project_root/previous-run/task.diff" <<'EOF'
diff --git a/src/Compiler/Retry.clasp b/src/Compiler/Retry.clasp
index 1111111..2222222 100644
--- a/src/Compiler/Retry.clasp
+++ b/src/Compiler/Retry.clasp
@@ -1,2 +1,3 @@
 old
+literal $(printf diff-substitution) ${HOME}
 keep
EOF

mkdir -p "$prompt_project_root/workspace" "$prompt_project_root/baseline" "$prompt_project_root/run"
prompt_workspace_path="$prompt_project_root/workspace-\$(printf workspace-path)-\${HOME}"
prompt_baseline_path="$prompt_project_root/baseline-\$(printf baseline-path)-\${HOME}"
mkdir -p "$prompt_workspace_path" "$prompt_baseline_path"

bash -lc "
  set -euo pipefail
  cd '$prompt_project_root'
  PATH='$prompt_project_root/tools':\"\$PATH\" HOME='$prompt_project_root/home' \
    CLASP_TEST_CODEX_MODE=builder \
    CLASP_TEST_PROMPT_CAPTURE='$prompt_project_root/builder.prompt' \
    CLASP_TEST_ENV_CAPTURE='$prompt_project_root/builder.env' \
    bash scripts/clasp-builder.sh \
      '$prompt_project_root/task-literal.md' \
      '$prompt_workspace_path' \
      '$prompt_project_root/run/builder-report.json' \
      '$prompt_project_root/run/builder-log.jsonl' \
      '$prompt_project_root/previous-run/verifier-report.json'

  grep -F '\$(printf prompt-substitution)' '$prompt_project_root/builder.prompt' >/dev/null
  grep -F '\${HOME}' '$prompt_project_root/builder.prompt' >/dev/null
  grep -F 'Previous verifier said \$(printf verifier-summary) should stay literal.' '$prompt_project_root/builder.prompt' >/dev/null
  grep -F 'touch /tmp/feedback' '$prompt_project_root/builder.prompt' >/dev/null
  grep -F 'Previous attempt build evidence:' '$prompt_project_root/builder.prompt' >/dev/null
  grep -F 'Treat this as context for the retry, not as automatically correct code.' '$prompt_project_root/builder.prompt' >/dev/null
  grep -F 'Previous builder touched \$(printf builder-summary) literally.' '$prompt_project_root/builder.prompt' >/dev/null
  grep -F 'src/Compiler/Retry.clasp' '$prompt_project_root/builder.prompt' >/dev/null
  grep -F 'bash scripts/test-retry-context.sh' '$prompt_project_root/builder.prompt' >/dev/null
  grep -F 'literal \$(printf diff-substitution) \${HOME}' '$prompt_project_root/builder.prompt' >/dev/null
  grep -F 'Do not replace the checkout or copy in a fresh repo snapshot.' '$prompt_project_root/builder.prompt' >/dev/null
  grep -F 'If Git metadata is missing or the checkout looks incomplete, stop and report that as an infrastructure failure instead of reconstructing the repo yourself.' '$prompt_project_root/builder.prompt' >/dev/null
  grep -F 'Do not rewrite the workspace root, remove \`.git\`, or materialize a new checkout.' '$prompt_project_root/builder.prompt' >/dev/null
  grep -F 'run the narrowest checks that cover your changes before finishing' '$prompt_project_root/builder.prompt' >/dev/null
  grep -F 'Do not run \`bash scripts/verify-all.sh\`' '$prompt_project_root/builder.prompt' >/dev/null
  grep -F 'the verifier and final merge gate own the repo-wide verification step.' '$prompt_project_root/builder.prompt' >/dev/null
  ! grep -F 'Before finishing, run bash scripts/verify-all.sh.' '$prompt_project_root/builder.prompt' >/dev/null
  grep -E '^HOME=.*/clasp-codex-runtime-home\\.[^/]+$' '$prompt_project_root/builder.env' >/dev/null
  grep -E '^XDG_CACHE_HOME=.*/clasp-codex-runtime-home\\.[^/]+/.cache$' '$prompt_project_root/builder.env' >/dev/null
  grep -E '^TMPDIR=.*/clasp-codex-runtime-home\\.[^/]+/tmp$' '$prompt_project_root/builder.env' >/dev/null

  PATH='$prompt_project_root/tools':\"\$PATH\" HOME='$prompt_project_root/home' \
    CLASP_TEST_CODEX_MODE=verifier \
    CLASP_TEST_PROMPT_CAPTURE='$prompt_project_root/verifier.prompt' \
    CLASP_TEST_ENV_CAPTURE='$prompt_project_root/verifier.env' \
    bash scripts/clasp-verifier.sh \
      '$prompt_project_root/task-literal.md' \
      '$prompt_workspace_path' \
      '$prompt_baseline_path' \
      '$prompt_project_root/run/verifier-report.json' \
      '$prompt_project_root/run/verifier-log.jsonl'

  grep -F 'Baseline workspace: $prompt_baseline_path' '$prompt_project_root/verifier.prompt' >/dev/null
  grep -F '\$(printf baseline-path)' '$prompt_project_root/verifier.prompt' >/dev/null
  grep -F '\${HOME}' '$prompt_project_root/verifier.prompt' >/dev/null
  grep -F '\$(printf prompt-substitution)' '$prompt_project_root/verifier.prompt' >/dev/null
  grep -F '\${HOME}' '$prompt_project_root/verifier.prompt' >/dev/null
  grep -F 'run the narrowest task-focused verification needed to establish correctness' '$prompt_project_root/verifier.prompt' >/dev/null
  grep -F 'Do not fail solely because \`bash scripts/verify-all.sh\` cannot run inside this sandboxed verifier.' '$prompt_project_root/verifier.prompt' >/dev/null
  grep -F 'The final merge gate runs the authoritative \`bash scripts/verify-all.sh\` on trunk before landing.' '$prompt_project_root/verifier.prompt' >/dev/null
  ! grep -F 'Treat \`bash scripts/verify-all.sh\` as the required verification gate.' '$prompt_project_root/verifier.prompt' >/dev/null
  grep -E '^HOME=.*/clasp-codex-runtime-home\\.[^/]+$' '$prompt_project_root/verifier.env' >/dev/null
  grep -E '^XDG_CACHE_HOME=.*/clasp-codex-runtime-home\\.[^/]+/.cache$' '$prompt_project_root/verifier.env' >/dev/null
  grep -E '^TMPDIR=.*/clasp-codex-runtime-home\\.[^/]+/tmp$' '$prompt_project_root/verifier.env' >/dev/null
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
  CLASP_SWARM_RETRY_LIMIT=1 bash scripts/clasp-swarm-lane.sh agents/swarm/test-wave/01-merge-gate >/dev/null 2>&1

  [[ \$(git rev-parse main) == \$(git rev-parse agents/swarm-trunk) ]]
  [[ \$(< feature.txt) == 'builder-change' ]]
  [[ \$(< verifier-only.txt) == 'verified-by-verifier' ]]
  [[ ! -e remove-me.txt ]]
  [[ -f .clasp-swarm/test-wave/01-merge-gate/completed/SW-005 ]]
  run_dir=\$(find .clasp-swarm/test-wave/01-merge-gate/runs -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [[ -n \"\$run_dir\" ]]
  [[ -f \"\$run_dir/integration.log\" ]]
" >/dev/null

lane_merge_gate_snapshot_test_root="$(mktemp -d)"
lane_merge_gate_snapshot_project_root="$(make_lane_merge_snapshot_gate_test_project "$lane_merge_gate_snapshot_test_root")"

bash -lc "
  set -euo pipefail
  cd '$lane_merge_gate_snapshot_project_root'
  CLASP_SWARM_TEST_POST_VERIFIER_HOOK=\"printf 'unverified-after-verifier\\n' > \\\"\\\$CLASP_SWARM_TEST_TASK_WORKTREE/post-verify-only.txt\\\"\" \
    bash scripts/clasp-swarm-lane.sh agents/swarm/test-wave/01-merge-gate >/dev/null 2>&1

  [[ \$(git rev-parse main) == \$(git rev-parse agents/swarm-trunk) ]]
  [[ \$(< feature.txt) == 'builder-change' ]]
  [[ \$(< verifier-only.txt) == 'verified-by-verifier' ]]
  [[ ! -e post-verify-only.txt ]]
  run_dir=\$(find .clasp-swarm/test-wave/01-merge-gate/runs -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [[ -n \"\$run_dir\" ]]
  [[ -f \"\$run_dir/verified-workspace-snapshot/verifier-only.txt\" ]]
  [[ ! -e \"\$run_dir/verified-workspace-snapshot/post-verify-only.txt\" ]]
" >/dev/null

lane_merge_noop_test_root="$(mktemp -d)"
lane_merge_noop_project_root="$(make_lane_merge_test_project "$lane_merge_noop_test_root")"

bash -lc "
  set -euo pipefail
  cd '$lane_merge_noop_project_root'

  cat > scripts/clasp-builder.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

task_file=\"\$1\"
workspace=\"\$2\"
report_json=\"\$3\"
log_jsonl=\"\$4\"
task_id=\"\$(basename \"\$task_file\" .md)\"

printf 'base\n' > \"\$workspace/feature.txt\"

cat > \"\$report_json\" <<JSON
{
  \"summary\": \"builder finished for \$task_id\",
  \"files_touched\": [],
  \"tests_run\": [],
  \"residual_risks\": []
}
JSON

: > \"\$log_jsonl\"
EOF

  cat > scripts/clasp-verifier.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

task_file=\"\$1\"
workspace=\"\$2\"
baseline_workspace=\"\$3\"
report_json=\"\$4\"
log_jsonl=\"\$5\"
task_id=\"\$(basename \"\$task_file\" .md)\"

cat > \"\$report_json\" <<JSON
{
  \"verdict\": \"pass\",
  \"summary\": \"verified \$task_id\",
  \"findings\": [],
  \"tests_run\": [],
  \"follow_up\": []
}
JSON

: > \"\$log_jsonl\"
EOF

  chmod +x scripts/clasp-builder.sh scripts/clasp-verifier.sh

  CLASP_SWARM_RETRY_LIMIT=1 bash scripts/clasp-swarm-lane.sh agents/swarm/test-wave/01-merge-gate >/dev/null 2>&1

  [[ \$(git rev-parse main) == \$(git rev-parse agents/swarm-trunk) ]]
  [[ ! -f .clasp-swarm/test-wave/01-merge-gate/completed/SW-005 ]]
  run_dir=\$(find .clasp-swarm/test-wave/01-merge-gate/runs -mindepth 1 -maxdepth 1 -type d | head -n 1)
  [[ -n \"\$run_dir\" ]]
  [[ -f \"\$run_dir/integration.log\" ]]
  grep -F 'accepted snapshot tree matched' \"\$run_dir/integration.log\" >/dev/null
  grep -F 'Merge gate or final verification failed before the task could be integrated.' \"\$run_dir/verifier-report.json\" >/dev/null
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
  cat > \"\$stale_run/builder-report.json\" <<'EOF'
{
  \"summary\": \"stale builder report\",
  \"files_touched\": [],
  \"tests_run\": [],
  \"residual_risks\": []
}
EOF
  git branch \"\$task_branch\" agents/swarm-trunk >/dev/null
  mkdir -p \"\$task_worktree\"
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

lane_worktree_retry_test_root="$(mktemp -d)"
lane_worktree_retry_project_root="$(make_lane_worktree_retry_test_project "$lane_worktree_retry_test_root")"

bash -lc "
  set -euo pipefail
  cd '$lane_worktree_retry_project_root'
  bash scripts/clasp-swarm-lane.sh agents/swarm/test-wave/01-worktree-retry >/dev/null 2>&1

  runs_root='.clasp-swarm/test-wave/01-worktree-retry/runs'
  run_count=\$(find \"\$runs_root\" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d '[:space:]')
  [[ \"\$run_count\" == '2' ]]
  first_run=\$(find \"\$runs_root\" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)
  second_run=\$(find \"\$runs_root\" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)
  [[ -f \"\$first_run/verifier-report.json\" ]]
  grep -F '\"verdict\": \"fail\"' \"\$first_run/verifier-report.json\" >/dev/null
  [[ -f \"\$second_run/builder-report.json\" ]]
  [[ -f \"\$second_run/verifier-report.json\" ]]
  [[ -f .clasp-swarm/completed/SW-007 ]]
  [[ \"\$(< feature.txt)\" == 'recovered-builder-change' ]]
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

autopilot_test_root_3="$(mktemp -d)"
autopilot_project_root_3="$(make_autopilot_test_project "$autopilot_test_root_3" "pass-workaround")"
write_task_manifest "$autopilot_project_root_3/agents/tasks/AA-001-parent.md" "AA-001 Parent" "None"

bash -lc "
  set -euo pipefail
  cd '$autopilot_project_root_3'
  PATH='$autopilot_project_root_3/tools':\"\$PATH\" CLASP_AUTOPILOT_RETRY_LIMIT=2 CLASP_AUTOPILOT_MAX_TASKS=1 bash scripts/clasp-autopilot.sh >/dev/null 2>&1

  [[ ! -f .clasp-agents/completed/AA-001-parent ]]
  [[ ! -f .clasp-agents/blocked/AA-001-parent.json ]]
  [[ ! -f .clasp-agents/blocked/AA-001-parent--workaround.json ]]
  [[ ! -f .clasp-agents/generated-tasks/AA-001-parent--workaround.md ]]
  run_dir=\$(find .clasp-agents/runs -maxdepth 1 -mindepth 1 -type d -name '*-AA-001-parent--workaround-attempt1' | head -n 1)
  [[ -n \"\$run_dir\" ]]
  [[ -f \"\$run_dir/verifier-report.json\" ]]
  [[ \$(< test-events.log) == \$'builder:AA-001-parent\nverifier:AA-001-parent:fail\nbuilder:AA-001-parent\nverifier:AA-001-parent:fail\nbuilder:AA-001-parent--workaround\nverifier:AA-001-parent--workaround:pass' ]]

  PATH='$autopilot_project_root_3/tools':\"\$PATH\" CLASP_AUTOPILOT_RETRY_LIMIT=2 bash scripts/clasp-autopilot.sh >/dev/null 2>&1

  [[ -f .clasp-agents/completed/AA-001-parent ]]
  [[ ! -f .clasp-agents/blocked/AA-001-parent.json ]]
  [[ ! -f .clasp-agents/generated-tasks/AA-001-parent--workaround.md ]]
  [[ \$(< test-events.log) == \$'builder:AA-001-parent\nverifier:AA-001-parent:fail\nbuilder:AA-001-parent\nverifier:AA-001-parent:fail\nbuilder:AA-001-parent--workaround\nverifier:AA-001-parent--workaround:pass\nbuilder:AA-001-parent\nverifier:AA-001-parent:pass' ]]
" >/dev/null
