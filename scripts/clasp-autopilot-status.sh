#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_root="$project_root/.clasp-agents"
pid_file="$runtime_root/autopilot.pid"
job_file="$runtime_root/autopilot.job"
current_task_file="$runtime_root/current-task.txt"
log_file="$runtime_root/logs/autopilot.log"
completed_root="$runtime_root/completed"
blocked_root="$runtime_root/blocked"

if [[ -f "$job_file" ]]; then
  job_dir="$(sed -n '1p' "$job_file")"
  pid=""
  job_status=""
  if [[ -f "$job_dir/pid" ]]; then
    pid="$(tr -d '[:space:]' <"$job_dir/pid")"
  fi
  if [[ -f "$job_dir/status" ]]; then
    job_status="$(sed -n '1p' "$job_dir/status")"
  fi
  if [[ -n "$pid" && "$job_status" != "completed" && "$job_status" != "failed" && "$job_status" != "stopped" ]] &&
     kill -0 "$pid" >/dev/null 2>&1; then
    echo "status: running"
    echo "pid: $pid"
    echo "job: $job_dir"
  else
    echo "status: stopped"
    if [[ -n "$pid" ]]; then
      echo "stale pid file: $pid"
    fi
    if [[ -n "$job_status" ]]; then
      echo "job status: $job_status"
    fi
  fi
elif [[ -f "$pid_file" ]]; then
  pid="$(cat "$pid_file")"
  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "status: running"
    echo "pid: $pid"
    echo "managed: false"
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
