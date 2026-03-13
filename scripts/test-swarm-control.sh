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

cleanup() {
  rm -rf "${runs_root:-}" "${markers_root:-}" "${repo_root:-}" "${lane_root:-}" "${completed_root:-}" "${blocked_root:-}" "${global_completed_root:-}"
}

trap cleanup EXIT

bash -n \
  "$project_root/scripts/clasp-swarm-common.sh" \
  "$project_root/scripts/clasp-swarm-lane.sh" \
  "$project_root/scripts/clasp-swarm-start.sh" \
  "$project_root/scripts/clasp-swarm-status.sh" \
  "$project_root/scripts/clasp-swarm-stop.sh"

bash -lc "
  set -euo pipefail
  source '$project_root/scripts/clasp-swarm-common.sh'
  [[ \$(clasp_swarm_task_key 'SW-001-do-something.md') == 'SW-001' ]]
  [[ \$(clasp_swarm_task_key 'agents/swarm/full/02-core-language/LG-019-type-inference.md') == 'LG-019' ]]
  clasp_swarm_retry_limit_is_bounded '2'
  ! clasp_swarm_retry_limit_is_bounded '0'
  ! clasp_swarm_retry_limit_is_bounded '-1'
  ! clasp_swarm_retry_limit_is_bounded 'forever'
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

mapfile -t lanes < <(bash "$project_root/scripts/clasp-swarm-start.sh" --list-lanes wave1)

if [[ "${#lanes[@]}" -lt 1 ]]; then
  echo "expected at least one wave1 lane" >&2
  exit 1
fi

for lane_dir in "${lanes[@]}"; do
  bash "$project_root/scripts/clasp-swarm-lane.sh" --list-tasks "$lane_dir" >/dev/null
done

bash "$project_root/scripts/clasp-swarm-status.sh" wave1 >/dev/null

mapfile -t default_lanes < <(bash "$project_root/scripts/clasp-swarm-start.sh" --list-lanes)

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

lane_root="$(mktemp -d)"
completed_root="$(mktemp -d)"
blocked_root="$(mktemp -d)"
global_completed_root="$(mktemp -d)"

cat > "$lane_root/ZZ-001-late-consumer.md" <<'EOF'
# ZZ-001

## Dependencies

- `ZZ-003`

## Acceptance

- done
EOF

cat > "$lane_root/ZZ-002-ready-now.md" <<'EOF'
# ZZ-002

## Acceptance

- done
EOF

cat > "$lane_root/ZZ-003-prerequisite.md" <<'EOF'
# ZZ-003

## Acceptance

- done
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
