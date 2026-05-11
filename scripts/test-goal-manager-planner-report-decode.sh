#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
claspc_bin="$("$project_root/scripts/resolve-claspc.sh")"

output="$("$claspc_bin" run "$project_root/examples/swarm-native/PlannerReportDecodeHarness.clasp")"

grep -F 'malformed-empty-tasks=err:planner report missing required fields' <<<"$output" >/dev/null
grep -F 'current-empty-tasks=ok:0:current empty' <<<"$output" >/dev/null
grep -F 'current-task=ok:1:current one' <<<"$output" >/dev/null
grep -F 'legacy-task=ok:1:legacy one' <<<"$output" >/dev/null

printf 'goal-manager-planner-report-decode-ok\n'
