#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/scripts/clasp-swarm-common.sh"

usage() {
  echo "usage: $0 [--json] [wave-name]" >&2
}

json_mode=0

case "${1:-}" in
  --json)
    json_mode=1
    shift
    ;;
esac

if [[ $# -gt 1 ]]; then
  usage
  exit 1
fi

wave_name="${1:-$(clasp_swarm_default_wave)}"
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
status_tsv="$(mktemp "${TMPDIR:-/tmp}/clasp-swarm-status.XXXXXX")"
summary_running=0
summary_stopped=0
summary_active=0
summary_blocked=0
summary_idle=0
summary_completed=0
summary_blocked_tasks=0
summary_stale_pids=0

cleanup() {
  rm -f "$status_tsv"
}

trap cleanup EXIT

while IFS= read -r lane_dir; do
  lane_name="$(clasp_swarm_lane_name "$lane_dir")"
  runtime_root="$project_root/.clasp-swarm/$wave_name/$lane_name"
  pid_file="$runtime_root/pid"
  current_task_file="$runtime_root/current-task.txt"
  completed_root="$runtime_root/completed"
  blocked_root="$runtime_root/blocked"
  log_file="$runtime_root/lane.log"
  process_status="stopped"
  run_state="idle"
  pid=""
  stale_pid=0

  if [[ -f "$pid_file" ]]; then
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" >/dev/null 2>&1; then
      process_status="running"
    else
      stale_pid=1
    fi
  fi

  current_task=""
  if [[ -f "$current_task_file" ]]; then
    current_task="$(cat "$current_task_file")"
  fi

  completed_count=0
  blocked_count=0

  if [[ -d "$completed_root" ]]; then
    completed_count="$(find "$completed_root" -type f | wc -l | tr -d ' ')"
  fi

  if [[ -d "$blocked_root" ]]; then
    blocked_count="$(find "$blocked_root" -type f | wc -l | tr -d ' ')"
  fi

  if [[ "$blocked_count" -gt 0 ]]; then
    run_state="blocked"
  elif [[ "$process_status" == "running" || -n "$current_task" ]]; then
    run_state="active"
  fi

  if [[ "$process_status" == "running" ]]; then
    summary_running=$((summary_running + 1))
  else
    summary_stopped=$((summary_stopped + 1))
  fi

  case "$run_state" in
    active)
      summary_active=$((summary_active + 1))
      ;;
    blocked)
      summary_blocked=$((summary_blocked + 1))
      ;;
    idle)
      summary_idle=$((summary_idle + 1))
      ;;
  esac

  summary_completed=$((summary_completed + completed_count))
  summary_blocked_tasks=$((summary_blocked_tasks + blocked_count))
  summary_stale_pids=$((summary_stale_pids + stale_pid))

  log_path=""
  if [[ -f "$log_file" ]]; then
    log_path="$log_file"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$lane_name" \
    "$process_status" \
    "$run_state" \
    "$pid" \
    "$stale_pid" \
    "$current_task" \
    "$completed_count" \
    "$blocked_count" \
    "$log_path" >> "$status_tsv"

  if [[ "$json_mode" == "1" ]]; then
    continue
  fi

  echo "lane: $lane_name"
  echo "  status: $process_status"
  echo "  run state: $run_state"

  if [[ -n "$pid" && "$stale_pid" == "0" ]]; then
    echo "  pid: $pid"
  elif [[ -n "$pid" ]]; then
    echo "  stale pid: $pid"
  fi

  if [[ -n "$current_task" ]]; then
    echo "  current task: $current_task"
  fi

  echo "  completed: $completed_count"
  echo "  blocked: $blocked_count"

  if [[ -f "$log_file" ]]; then
    echo "  log: $log_file"
    tail -n 5 "$log_file" | sed 's/^/    /'
  fi
done < <(clasp_swarm_lane_dirs "$wave_name" "$project_root")

summary_lanes=$((summary_running + summary_stopped))

if [[ "$json_mode" == "1" ]]; then
  node - "$wave_name" "$generated_at" "$status_tsv" "$summary_lanes" "$summary_running" "$summary_stopped" "$summary_active" "$summary_blocked" "$summary_idle" "$summary_completed" "$summary_blocked_tasks" "$summary_stale_pids" <<'EOF'
const fs = require("fs");
const [
  waveName,
  generatedAt,
  statusPath,
  laneCount,
  runningCount,
  stoppedCount,
  activeCount,
  blockedCount,
  idleCount,
  completedTasks,
  blockedTasks,
  stalePidCount,
] = process.argv.slice(2);

const lines = fs.existsSync(statusPath)
  ? fs.readFileSync(statusPath, "utf8").split(/\r?\n/).filter(Boolean)
  : [];

const lanes = lines.map((line) => {
  const [
    lane,
    status,
    runState,
    pid,
    stalePid,
    currentTask,
    completed,
    blocked,
    logPath,
  ] = line.split("\t");

  return {
    lane,
    status,
    run_state: runState,
    pid: pid.length > 0 ? Number(pid) : null,
    stale_pid: stalePid === "1",
    current_task: currentTask.length > 0 ? currentTask : null,
    completed_count: Number(completed),
    blocked_count: Number(blocked),
    log_path: logPath.length > 0 ? logPath : null,
  };
});

const payload = {
  wave: waveName,
  generated_at: generatedAt,
  summary: {
    lane_count: Number(laneCount),
    running_lanes: Number(runningCount),
    stopped_lanes: Number(stoppedCount),
    active_lanes: Number(activeCount),
    blocked_lanes: Number(blockedCount),
    idle_lanes: Number(idleCount),
    completed_tasks: Number(completedTasks),
    blocked_tasks: Number(blockedTasks),
    stale_pid_lanes: Number(stalePidCount),
  },
  lanes,
};

process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
EOF
  exit 0
fi

echo "summary:"
echo "  wave: $wave_name"
echo "  lanes: $summary_lanes"
echo "  running lanes: $summary_running"
echo "  stopped lanes: $summary_stopped"
echo "  active lanes: $summary_active"
echo "  blocked lanes: $summary_blocked"
echo "  idle lanes: $summary_idle"
echo "  completed tasks: $summary_completed"
echo "  blocked tasks: $summary_blocked_tasks"
echo "  stale pid lanes: $summary_stale_pids"
