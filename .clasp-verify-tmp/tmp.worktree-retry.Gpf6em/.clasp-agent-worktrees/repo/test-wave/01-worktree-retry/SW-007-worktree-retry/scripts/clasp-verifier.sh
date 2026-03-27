#!/usr/bin/env bash
set -euo pipefail
task_file="$1"
workspace="$2"
baseline_workspace="$3"
report_json="$4"
log_jsonl="$5"
task_id="$(basename "$task_file" .md)"
[[ "$(< "$baseline_workspace/feature.txt")" == "base" ]]
[[ "$(< "$workspace/feature.txt")" == "recovered-builder-change" ]]
cat > "$report_json" <<JSON
{"verdict":"pass","summary":"verified $task_id","findings":[],"tests_run":["broken worktree retry scenario"],"follow_up":[]}
JSON
: > "$log_jsonl"
