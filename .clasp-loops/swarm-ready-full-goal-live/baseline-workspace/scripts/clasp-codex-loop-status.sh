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
log_file="$runtime_dir/loop.log"

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

echo "runtime: $runtime_dir"
if [[ -f "$log_file" ]]; then
  echo "log: $log_file"
  tail -n 20 "$log_file"
fi
