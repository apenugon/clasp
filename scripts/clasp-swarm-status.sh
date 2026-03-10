#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/scripts/clasp-swarm-common.sh"

wave_name="${1:-$(clasp_swarm_default_wave)}"

while IFS= read -r lane_dir; do
  lane_name="$(clasp_swarm_lane_name "$lane_dir")"
  runtime_root="$project_root/.clasp-swarm/$wave_name/$lane_name"
  pid_file="$runtime_root/pid"
  current_task_file="$runtime_root/current-task.txt"
  completed_root="$runtime_root/completed"
  blocked_root="$runtime_root/blocked"
  log_file="$runtime_root/lane.log"

  echo "lane: $lane_name"

  if [[ -f "$pid_file" ]]; then
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" >/dev/null 2>&1; then
      echo "  status: running"
      echo "  pid: $pid"
    else
      echo "  status: stopped"
      echo "  stale pid: $pid"
    fi
  else
    echo "  status: stopped"
  fi

  if [[ -f "$current_task_file" ]]; then
    echo "  current task: $(cat "$current_task_file")"
  fi

  completed_count=0
  blocked_count=0

  if [[ -d "$completed_root" ]]; then
    completed_count="$(find "$completed_root" -type f | wc -l | tr -d ' ')"
  fi

  if [[ -d "$blocked_root" ]]; then
    blocked_count="$(find "$blocked_root" -type f | wc -l | tr -d ' ')"
  fi

  echo "  completed: $completed_count"
  echo "  blocked: $blocked_count"

  if [[ -f "$log_file" ]]; then
    echo "  log: $log_file"
    tail -n 5 "$log_file" | sed 's/^/    /'
  fi
done < <(clasp_swarm_lane_dirs "$wave_name" "$project_root")
