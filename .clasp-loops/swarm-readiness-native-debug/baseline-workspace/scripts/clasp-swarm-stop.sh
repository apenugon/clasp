#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/scripts/clasp-swarm-common.sh"

wave_name="${1:-$(clasp_swarm_default_wave)}"
shutdown_wait_seconds="${CLASP_SWARM_STOP_WAIT_SECONDS:-10}"

kill_descendants() {
  local parent_pid="$1"
  local child_pid=""

  if ! command -v pgrep >/dev/null 2>&1; then
    return 0
  fi

  while IFS= read -r child_pid; do
    [[ -n "$child_pid" ]] || continue
    kill_descendants "$child_pid"
    kill "$child_pid" >/dev/null 2>&1 || true
  done < <(pgrep -P "$parent_pid" || true)
}

while IFS= read -r lane_dir; do
  lane_name="$(clasp_swarm_lane_name "$lane_dir")"
  runtime_root="$project_root/.clasp-swarm/$wave_name/$lane_name"
  pid_file="$runtime_root/pid"

  if [[ ! -f "$pid_file" ]]; then
    echo "lane $lane_name is not running"
    continue
  fi

  pid="$(cat "$pid_file")"

  if kill -0 "$pid" >/dev/null 2>&1; then
    kill_descendants "$pid"
    kill "$pid"
    deadline=$((SECONDS + shutdown_wait_seconds))

    while kill -0 "$pid" >/dev/null 2>&1; do
      if (( SECONDS >= deadline )); then
        kill_descendants "$pid"
        kill -9 "$pid" >/dev/null 2>&1 || true
        break
      fi
      sleep 0.2
    done

    echo "stopped lane=$lane_name pid=$pid"
  else
    echo "lane $lane_name had stale pid $pid"
  fi

  rm -f "$pid_file"
done < <(clasp_swarm_lane_dirs "$wave_name" "$project_root")
