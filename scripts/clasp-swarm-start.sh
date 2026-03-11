#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/scripts/clasp-swarm-common.sh"

wave_name="${1:-$(clasp_swarm_default_wave)}"
trunk_branch="${CLASP_SWARM_TRUNK_BRANCH:-agents/swarm-trunk}"
main_branch="${CLASP_SWARM_MAIN_BRANCH:-main}"
source_ref="${CLASP_SWARM_SOURCE_REF:-HEAD}"
allow_dirty="${CLASP_SWARM_ALLOW_DIRTY:-0}"

if [[ "${1:-}" == "--list-lanes" ]]; then
  wave_name="${2:-$(clasp_swarm_default_wave)}"
  clasp_swarm_lane_dirs "$wave_name" "$project_root"
  exit 0
fi

if [[ "$allow_dirty" != "1" ]] && \
   { ! git -C "$project_root" diff --quiet --ignore-submodules --exit-code || \
     ! git -C "$project_root" diff --cached --quiet --ignore-submodules --exit-code || \
     [[ -n "$(git -C "$project_root" ls-files --others --exclude-standard)" ]]; }; then
  echo "refusing to start the swarm from a dirty repo; commit or stash changes first" >&2
  exit 1
fi

current_branch="$(clasp_swarm_current_branch "$project_root")"
if [[ "$current_branch" != "$main_branch" ]]; then
  echo "refusing to start the swarm unless the repo is checked out on $main_branch; current branch is $current_branch" >&2
  exit 1
fi

if ! git -C "$project_root" show-ref --verify --quiet "refs/heads/$trunk_branch"; then
  git -C "$project_root" branch "$trunk_branch" "$source_ref"
fi

clasp_swarm_reconcile_main_and_trunk "$project_root" "$main_branch" "$trunk_branch" >/dev/null

while IFS= read -r lane_dir; do
  lane_name="$(clasp_swarm_lane_name "$lane_dir")"
  runtime_root="$project_root/.clasp-swarm/$wave_name/$lane_name"
  log_file="$runtime_root/lane.log"
  pid_file="$runtime_root/pid"

  mkdir -p "$runtime_root"

  if [[ -f "$pid_file" ]]; then
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" >/dev/null 2>&1; then
      echo "lane $lane_name already running with pid $pid"
      continue
    fi
    rm -f "$pid_file"
  fi

  setsid bash -lc "exec bash \"$project_root/scripts/clasp-swarm-lane.sh\" \"$lane_dir\"" \
    >"$log_file" 2>&1 < /dev/null &
  pid=$!
  printf '%s\n' "$pid" > "$pid_file"
  echo "started lane=$lane_name pid=$pid log=$log_file"
done < <(clasp_swarm_lane_dirs "$wave_name" "$project_root")
