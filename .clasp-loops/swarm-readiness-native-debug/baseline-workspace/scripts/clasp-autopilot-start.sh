#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_root="$project_root/.clasp-agents"
log_file="$runtime_root/logs/autopilot.log"
pid_file="$runtime_root/autopilot.pid"

mkdir -p "$runtime_root/logs"

if [[ -f "$pid_file" ]]; then
  pid="$(cat "$pid_file")"
  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "autopilot already running with pid $pid" >&2
    exit 1
  fi
  rm -f "$pid_file"
fi

setsid bash -lc "exec bash \"$project_root/scripts/clasp-autopilot.sh\"" >"$log_file" 2>&1 < /dev/null &
pid=$!
printf '%s\n' "$pid" > "$pid_file"
echo "started autopilot pid=$pid log=$log_file"
