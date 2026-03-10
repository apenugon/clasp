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
metrics_tsv="$(mktemp "${TMPDIR:-/tmp}/clasp-swarm-summary.XXXXXX")"

cleanup() {
  rm -f "$metrics_tsv"
}

trap cleanup EXIT

while IFS= read -r lane_dir; do
  lane_name="$(clasp_swarm_lane_name "$lane_dir")"
  runs_root="$project_root/.clasp-swarm/$wave_name/$lane_name/runs"
  if [[ ! -d "$runs_root" ]]; then
    continue
  fi

  while IFS= read -r metrics_file; do
    node - <<'EOF' "$metrics_file" >> "$metrics_tsv"
const fs = require("fs");
const metricsPath = process.argv[2];
const data = JSON.parse(fs.readFileSync(metricsPath, "utf8"));
[
  data.task_family,
  data.task_id,
  data.outcome,
  data.phase,
  data.timed_out ? "1" : "0",
  Number(data.duration_seconds || 0),
].forEach((value, index, fields) => {
  process.stdout.write(String(value));
  process.stdout.write(index + 1 === fields.length ? "\n" : "\t");
});
EOF
  done < <(find "$runs_root" -mindepth 2 -maxdepth 2 -type f -name 'metrics.json' | sort)
done < <(clasp_swarm_lane_dirs "$wave_name" "$project_root")

if [[ "$json_mode" == "1" ]]; then
  node - <<'EOF' "$wave_name" "$metrics_tsv"
const fs = require("fs");
const [waveName, metricsPath] = process.argv.slice(2);
const lines = fs.existsSync(metricsPath)
  ? fs.readFileSync(metricsPath, "utf8").split(/\r?\n/).filter(Boolean)
  : [];

const families = new Map();

for (const line of lines) {
  const [taskFamily, taskId, outcome, phase, timedOut, durationSeconds] = line.split("\t");
  if (!families.has(taskFamily)) {
    families.set(taskFamily, {
      task_family: taskFamily,
      attempts: 0,
      passed: 0,
      timed_out: 0,
      total_duration_seconds: 0,
      task_ids: new Set(),
      phases: new Set(),
    });
  }
  const entry = families.get(taskFamily);
  entry.attempts += 1;
  if (outcome === "pass") {
    entry.passed += 1;
  }
  if (timedOut === "1") {
    entry.timed_out += 1;
  }
  entry.total_duration_seconds += Number(durationSeconds);
  entry.task_ids.add(taskId);
  entry.phases.add(phase);
}

const summary = Array.from(families.values())
  .sort((a, b) => a.task_family.localeCompare(b.task_family))
  .map((entry) => ({
    task_family: entry.task_family,
    attempts: entry.attempts,
    unique_tasks: entry.task_ids.size,
    passed_attempts: entry.passed,
    timed_out_attempts: entry.timed_out,
    pass_rate: entry.attempts === 0 ? 0 : entry.passed / entry.attempts,
    timeout_rate: entry.attempts === 0 ? 0 : entry.timed_out / entry.attempts,
    mean_time_seconds: entry.attempts === 0 ? 0 : entry.total_duration_seconds / entry.attempts,
    phases: Array.from(entry.phases).sort(),
  }));

process.stdout.write(`${JSON.stringify({ wave: waveName, families: summary }, null, 2)}\n`);
EOF
  exit 0
fi

node - <<'EOF' "$wave_name" "$metrics_tsv"
const fs = require("fs");
const [waveName, metricsPath] = process.argv.slice(2);
const lines = fs.existsSync(metricsPath)
  ? fs.readFileSync(metricsPath, "utf8").split(/\r?\n/).filter(Boolean)
  : [];

const families = new Map();

for (const line of lines) {
  const [taskFamily, taskId, outcome, phase, timedOut, durationSeconds] = line.split("\t");
  if (!families.has(taskFamily)) {
    families.set(taskFamily, {
      attempts: 0,
      passed: 0,
      timedOut: 0,
      totalDuration: 0,
      taskIds: new Set(),
      phases: new Set(),
    });
  }
  const entry = families.get(taskFamily);
  entry.attempts += 1;
  if (outcome === "pass") {
    entry.passed += 1;
  }
  if (timedOut === "1") {
    entry.timedOut += 1;
  }
  entry.totalDuration += Number(durationSeconds);
  entry.taskIds.add(taskId);
  entry.phases.add(phase);
}

console.log(`wave: ${waveName}`);
console.log("task family summary:");
for (const taskFamily of Array.from(families.keys()).sort((a, b) => a.localeCompare(b))) {
  const entry = families.get(taskFamily);
  const passRate = entry.attempts === 0 ? 0 : (entry.passed / entry.attempts) * 100;
  const timeoutRate = entry.attempts === 0 ? 0 : (entry.timedOut / entry.attempts) * 100;
  const meanTime = entry.attempts === 0 ? 0 : entry.totalDuration / entry.attempts;
  console.log(`family: ${taskFamily}`);
  console.log(`  attempts: ${entry.attempts}`);
  console.log(`  unique tasks: ${entry.taskIds.size}`);
  console.log(`  pass rate: ${passRate.toFixed(1)}%`);
  console.log(`  timeout rate: ${timeoutRate.toFixed(1)}%`);
  console.log(`  mean time: ${meanTime.toFixed(1)}s`);
  console.log(`  phases: ${Array.from(entry.phases).sort().join(", ")}`);
}
if (families.size === 0) {
  console.log("  no run metrics recorded yet");
}
EOF
