#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/scripts/clasp-swarm-common.sh"

usage() {
  echo "usage: $0 [--json] [wave-name]" >&2
}

count_files() {
  local target_dir="$1"

  if [[ -d "$target_dir" ]]; then
    find "$target_dir" -type f | wc -l | tr -d '[:space:]'
  else
    printf '0\n'
  fi
}

collect_latest_run_state() {
  local runs_root="$1"
  local lane_name="$2"

  latest_run_path=""
  latest_run_attempt=""
  latest_run_status=""
  latest_run_summary=""

  if [[ ! -d "$runs_root" ]]; then
    return 0
  fi

  latest_run_path="$(find "$runs_root" -maxdepth 1 -mindepth 1 -type d | sort | tail -n 1 || true)"

  if [[ -z "$latest_run_path" ]]; then
    return 0
  fi

  latest_run_attempt="$(clasp_swarm_task_run_attempt "$latest_run_path" 2>/dev/null || true)"

  read -r latest_run_status latest_run_summary < <(
    node - <<'EOF' "$latest_run_path/builder-report.json" "$latest_run_path/verifier-report.json" "$lane_name"
const fs = require("fs");
const [builderPath, verifierPath, laneName] = process.argv.slice(2);

function sanitize(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

let status = "started";
let summary = `Lane ${laneName} has an active run without a structured report yet.`;

if (fs.existsSync(verifierPath)) {
  try {
    const report = JSON.parse(fs.readFileSync(verifierPath, "utf8"));
    status = report.verdict === "pass" ? "pass" : "fail";
    summary = sanitize(report.summary) || summary;
  } catch (_) {
    status = "invalid-report";
    summary = `Lane ${laneName} produced an unreadable verifier report.`;
  }
} else if (fs.existsSync(builderPath)) {
  try {
    const report = JSON.parse(fs.readFileSync(builderPath, "utf8"));
    status = "builder-complete";
    summary = sanitize(report.summary) || `Lane ${laneName} completed the builder step.`;
  } catch (_) {
    status = "invalid-report";
    summary = `Lane ${laneName} produced an unreadable builder report.`;
  }
}

process.stdout.write(`${status}\t${summary}\n`);
EOF
  )
}

json_mode=0
wave_name="$(clasp_swarm_default_wave)"

if [[ $# -gt 2 ]]; then
  usage
  exit 1
fi

if [[ "${1:-}" == "--json" ]]; then
  json_mode=1
  wave_name="${2:-$(clasp_swarm_default_wave)}"
elif [[ $# -ge 1 ]]; then
  wave_name="$1"
fi

lane_text_file="$(mktemp)"
lane_jsonl_file="$(mktemp)"
run_state_file="$(mktemp)"

cleanup() {
  rm -f "$lane_text_file" "$lane_jsonl_file" "$run_state_file"
}

trap cleanup EXIT

lane_count=0
running_count=0
stopped_count=0
completed_total=0
blocked_total=0

while IFS= read -r lane_dir; do
  lane_name="$(clasp_swarm_lane_name "$lane_dir")"
  runtime_root="$project_root/.clasp-swarm/$wave_name/$lane_name"
  runs_root="$runtime_root/runs"
  pid_file="$runtime_root/pid"
  current_task_file="$runtime_root/current-task.txt"
  completed_root="$runtime_root/completed"
  blocked_root="$runtime_root/blocked"
  log_file="$runtime_root/lane.log"
  pid=""
  stale_pid=""
  status="stopped"
  current_task=""

  lane_count=$((lane_count + 1))

  if [[ -f "$pid_file" ]]; then
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" >/dev/null 2>&1; then
      status="running"
      running_count=$((running_count + 1))
    else
      stale_pid="$pid"
      pid=""
      stopped_count=$((stopped_count + 1))
    fi
  else
    stopped_count=$((stopped_count + 1))
  fi

  if [[ -f "$current_task_file" ]]; then
    current_task="$(cat "$current_task_file")"
  fi

  completed_count="$(count_files "$completed_root")"
  blocked_count="$(count_files "$blocked_root")"
  completed_total=$((completed_total + completed_count))
  blocked_total=$((blocked_total + blocked_count))

  collect_latest_run_state "$runs_root" "$lane_name"
  printf '%s\n' "${latest_run_status:-no-run}" >> "$run_state_file"

  {
    echo "lane: $lane_name"
    echo "  status: $status"
    if [[ -n "$pid" ]]; then
      echo "  pid: $pid"
    fi
    if [[ -n "$stale_pid" ]]; then
      echo "  stale pid: $stale_pid"
    fi
    if [[ -n "$current_task" ]]; then
      echo "  current task: $current_task"
    fi
    echo "  completed: $completed_count"
    echo "  blocked: $blocked_count"
    if [[ -n "$latest_run_path" ]]; then
      echo "  latest run: $(basename "$latest_run_path")"
      if [[ -n "$latest_run_attempt" ]]; then
        echo "  latest attempt: $latest_run_attempt"
      fi
      echo "  run status: $latest_run_status"
      echo "  run summary: $latest_run_summary"
    fi
    if [[ -f "$log_file" ]]; then
      echo "  log: $log_file"
      tail -n 5 "$log_file" | sed 's/^/    /'
    fi
  } >> "$lane_text_file"

  node - <<'EOF' \
    "$lane_name" \
    "$status" \
    "$pid" \
    "$stale_pid" \
    "$current_task" \
    "$completed_count" \
    "$blocked_count" \
    "$log_file" \
    "$latest_run_path" \
    "$latest_run_attempt" \
    "$latest_run_status" \
    "$latest_run_summary" >> "$lane_jsonl_file"
const fs = require("fs");
const [
  lane,
  status,
  pid,
  stalePid,
  currentTask,
  completedCount,
  blockedCount,
  logPath,
  latestRunPath,
  latestRunAttempt,
  latestRunStatus,
  latestRunSummary,
] = process.argv.slice(2);

function tailLines(filePath, count) {
  if (!filePath || !fs.existsSync(filePath)) {
    return [];
  }
  return fs
    .readFileSync(filePath, "utf8")
    .split(/\r?\n/)
    .filter((line) => line.length > 0)
    .slice(-count);
}

const laneStatus = {
  lane,
  status,
  pid: pid || null,
  stalePid: stalePid || null,
  currentTask: currentTask || null,
  completedCount: Number(completedCount),
  blockedCount: Number(blockedCount),
  logPath: logPath && fs.existsSync(logPath) ? logPath : null,
  recentLogLines: tailLines(logPath, 5),
  latestRun: latestRunPath
    ? {
        path: latestRunPath,
        attempt: latestRunAttempt ? Number(latestRunAttempt) : null,
        status: latestRunStatus || "started",
        summary: latestRunSummary || null,
      }
    : null,
};

process.stdout.write(`${JSON.stringify(laneStatus)}\n`);
EOF
done < <(clasp_swarm_lane_dirs "$wave_name" "$project_root")

if [[ "$json_mode" == "1" ]]; then
  node - <<'EOF' "$wave_name" "$lane_count" "$running_count" "$stopped_count" "$completed_total" "$blocked_total" "$lane_jsonl_file"
const fs = require("fs");
const [wave, laneCount, runningCount, stoppedCount, completedCount, blockedCount, laneJsonl] = process.argv.slice(2);
const lanes = fs.existsSync(laneJsonl)
  ? fs
      .readFileSync(laneJsonl, "utf8")
      .split(/\r?\n/)
      .filter(Boolean)
      .map((line) => JSON.parse(line))
  : [];
const runStateCounts = Object.fromEntries(
  lanes
    .reduce((counts, lane) => {
      const key = lane.latestRun?.status || "no-run";
      counts.set(key, (counts.get(key) || 0) + 1);
      return counts;
    }, new Map())
    .entries(),
);
const payload = {
  wave,
  summary: {
    laneCount: Number(laneCount),
    runningCount: Number(runningCount),
    stoppedCount: Number(stoppedCount),
    completedCount: Number(completedCount),
    blockedCount: Number(blockedCount),
    runStateCounts,
  },
  lanes,
};
process.stdout.write(`${JSON.stringify(payload, null, 2)}\n`);
EOF
  exit 0
fi

run_state_summary="$(
  node - <<'EOF' "$run_state_file"
const fs = require("fs");
const [runStateFile] = process.argv.slice(2);
const counts = new Map();
for (const state of fs.readFileSync(runStateFile, "utf8").split(/\r?\n/).filter(Boolean).sort()) {
  counts.set(state, (counts.get(state) || 0) + 1);
}
process.stdout.write(
  Array.from(counts.entries())
    .map(([state, count]) => `${state}=${count}`)
    .join(" "),
);
EOF
)"

echo "wave: $wave_name"
echo "summary: lanes=$lane_count running=$running_count stopped=$stopped_count completed=$completed_total blocked=$blocked_total"
echo "run-states: ${run_state_summary:-none}"

if [[ -s "$lane_text_file" ]]; then
  cat "$lane_text_file"
fi
