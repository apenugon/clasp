#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "usage: $0 <task-file> [workspace] [runtime-dir]" >&2
  exit 1
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_input="$1"
runtime_dir_input="${3:-}"
task_file="$(cd "$(dirname "$task_input")" && pwd)/$(basename "$task_input")"
task_id="$(basename "$task_file" .md)"
runtime_dir="${runtime_dir_input:-$project_root/.clasp-agents/$task_id}"
runtime_dir="$(mkdir -p "$runtime_dir" && cd "$runtime_dir" && pwd)"
pid_file="$runtime_dir/loop.pid"
job_file="$runtime_dir/loop.job"
log_file="$runtime_dir/loop.log"

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

echo "runtime: $runtime_dir"
if [[ -f "$log_file" ]]; then
  echo "log: $log_file"
  tail -n 20 "$log_file"
fi
