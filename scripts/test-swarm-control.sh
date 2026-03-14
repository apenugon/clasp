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

cleanup() {
  rm -rf "${runs_root:-}" "${markers_root:-}" "${repo_root:-}" "${lane_root:-}" "${completed_root:-}" "${blocked_root:-}" "${global_completed_root:-}" "${spawn_root:-}" "${spawn_path_root:-}" "${invalid_lane_root:-}"
}

trap cleanup EXIT

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
