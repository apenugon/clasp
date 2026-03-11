#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runs_root=""
markers_root=""

cleanup() {
  rm -rf "${runs_root:-}" "${markers_root:-}"
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
