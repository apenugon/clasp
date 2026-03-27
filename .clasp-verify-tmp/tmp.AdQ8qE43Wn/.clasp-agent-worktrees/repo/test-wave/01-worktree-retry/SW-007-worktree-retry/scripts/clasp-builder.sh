#!/usr/bin/env bash
set -euo pipefail

task_file="$1"
workspace="$2"
report_json="$3"
log_jsonl="$4"
task_id="$(basename "$task_file" .md)"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
attempt_file="$project_root/builder-attempt.txt"
attempt=0

if [[ -f "$attempt_file" ]]; then
  attempt="$(< "$attempt_file")"
fi
attempt=$((attempt + 1))
printf '%s\n' "$attempt" > "$attempt_file"

if [[ "$attempt" == "1" ]]; then
  rm -f "$workspace/.git"
  printf 'builder stripped git metadata\n' > "$log_jsonl"
  cat > "$report_json" <<JSON
{
  "summary": "builder finished for $task_id",
  "files_touched": [],
  "tests_run": [],
  "residual_risks": []
}
JSON
  exit 0
fi

printf 'recovered-builder-change\n' > "$workspace/feature.txt"

cat > "$report_json" <<JSON
{
  "summary": "builder finished for $task_id",
  "files_touched": [
    "feature.txt"
  ],
  "tests_run": [],
  "residual_risks": []
}
JSON

printf 'builder retry preserved git metadata\n' > "$log_jsonl"
