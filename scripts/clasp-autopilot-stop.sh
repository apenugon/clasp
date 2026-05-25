#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_root="$project_root/.clasp-agents"
pid_file="$runtime_root/autopilot.pid"
job_file="$runtime_root/autopilot.job"

if [[ -f "$job_file" ]]; then
  job_dir="$(sed -n '1p' "$job_file")"
  pid=""
  if [[ -f "$job_dir/pid" ]]; then
    pid="$(tr -d '[:space:]' <"$job_dir/pid")"
  fi
  "$project_root/scripts/stop-managed-job.sh" --jobs-root "$runtime_root/jobs" "$job_dir"
  rm -f "$pid_file" "$job_file"
  if [[ -n "$pid" ]]; then
    echo "stopped autopilot pid=$pid"
  else
    echo "stopped autopilot"
  fi
  exit 0
fi

if [[ ! -f "$pid_file" ]]; then
  echo "autopilot is not running"
  exit 0
fi

pid="$(cat "$pid_file")"

if kill -0 "$pid" >/dev/null 2>&1; then
  echo "autopilot has unmanaged pid $pid; refusing to signal without managed-job metadata" >&2
  exit 1
else
  echo "autopilot pid file was stale: $pid"
fi

rm -f "$pid_file"
