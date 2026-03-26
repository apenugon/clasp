#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_root="$project_root/.clasp-agents"
pid_file="$runtime_root/autopilot.pid"

if [[ ! -f "$pid_file" ]]; then
  echo "autopilot is not running"
  exit 0
fi

pid="$(cat "$pid_file")"

if kill -0 "$pid" >/dev/null 2>&1; then
  kill "$pid"
  echo "stopped autopilot pid=$pid"
else
  echo "autopilot pid file was stale: $pid"
fi

rm -f "$pid_file"
