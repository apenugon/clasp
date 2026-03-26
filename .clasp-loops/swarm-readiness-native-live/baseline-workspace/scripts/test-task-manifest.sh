#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_file="$project_root/agents/swarm/full/01-swarm-infra/SW-001-replace-the-current-coarse-agents-tasks-backlog-with-a-granular-task-manifest-template-and-task-schema.md"

[[ -f "$project_root/agents/swarm/task-template.md" ]]
[[ -f "$project_root/agents/swarm/task.schema.json" ]]

node "$project_root/scripts/clasp-swarm-validate-task.mjs" "$task_file" >/dev/null
[[ "$(node "$project_root/scripts/clasp-swarm-validate-task.mjs" --print-field taskId "$task_file")" == 'SW-001-replace-the-current-coarse-agents-tasks-backlog-with-a-granular-task-manifest-template-and-task-schema' ]]
[[ "$(node "$project_root/scripts/clasp-swarm-validate-task.mjs" --print-field taskKey "$task_file")" == 'SW-001' ]]
[[ "$(node "$project_root/scripts/clasp-swarm-validate-task.mjs" --print-field batchLabel "$task_file")" == "" ]]
