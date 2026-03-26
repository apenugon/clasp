#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_root="$project_root/.clasp-agents"
pid_file="$runtime_root/autopilot.pid"
current_task_file="$runtime_root/current-task.txt"
log_file="$runtime_root/logs/autopilot.log"
completed_root="$runtime_root/completed"
blocked_root="$runtime_root/blocked"

if [[ -f "$pid_file" ]]; then
  pid="$(cat "$pid_file")"
  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "status: running"
    echo "pid: $pid"
  else
    echo "status: stopped"
    echo "stale pid file: $pid"
  fi
else
  echo "status: stopped"
fi

if [[ -f "$current_task_file" ]]; then
  echo "current task: $(cat "$current_task_file")"
fi

if [[ -d "$completed_root" ]]; then
  completed_count="$(find "$completed_root" -type f | wc -l | tr -d ' ')"
  echo "completed tasks: $completed_count"
fi

if [[ -d "$blocked_root" ]]; then
  blocked_count="$(find "$blocked_root" -type f | wc -l | tr -d ' ')"
  echo "blocked tasks: $blocked_count"
fi

if [[ -f "$log_file" ]]; then
  echo "log: $log_file"
  tail -n 20 "$log_file"
fi
