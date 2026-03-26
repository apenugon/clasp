#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "usage: $0 <task-file> [workspace] [runtime-dir]" >&2
  exit 1
fi

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_input="$1"
workspace_input="${2:-$project_root}"
runtime_dir_input="${3:-}"
workspace="$(cd "$workspace_input" && pwd)"
task_file="$(cd "$(dirname "$task_input")" && pwd)/$(basename "$task_input")"
task_id="$(basename "$task_file" .md)"
runtime_dir="${runtime_dir_input:-$project_root/.clasp-agents/$task_id}"
runtime_dir="$(mkdir -p "$runtime_dir" && cd "$runtime_dir" && pwd)"
pid_file="$runtime_dir/loop.pid"
log_file="$runtime_dir/loop.log"

source "$project_root/scripts/clasp-swarm-common.sh"

if [[ -f "$pid_file" ]]; then
  pid="$(cat "$pid_file")"
  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "codex loop already running with pid $pid" >&2
    exit 1
  fi
  rm -f "$pid_file"
fi

pid="$(clasp_swarm_spawn_detached "$log_file" bash "$project_root/scripts/clasp-codex-loop.sh" "$task_file" "$workspace" "$runtime_dir")"
printf '%s\n' "$pid" > "$pid_file"
echo "started codex loop pid=$pid log=$log_file runtime=$runtime_dir"
