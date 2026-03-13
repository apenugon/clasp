#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
results_root="$project_root/benchmarks/results"
tmp_bin="$(mktemp -d)"
synthetic_files=()

cleanup() {
  rm -rf "$tmp_bin"
  if [[ ${#synthetic_files[@]} -gt 0 ]]; then
    rm -f "${synthetic_files[@]}"
  fi
}

trap cleanup EXIT

write_result() {
  local filename="$1"
  local task_id="$2"
  local language="$3"
  local harness="$4"
  local model="$5"
  local notes="$6"
  local finished_at="$7"
  local duration_ms="$8"
  local total_tokens="$9"
  local uncached_total="${10}"
  local passed="${11}"
  local exit_code="${12}"
  local result_path="$results_root/$filename"

  synthetic_files+=("$result_path")

  cat >"$result_path" <<EOF
{
  "taskId": "$task_id",
  "suite": "clickable-lead-inbox",
  "language": "$language",
  "harness": "$harness",
  "model": "$model",
  "startedAt": "2026-03-01T10:00:00.000Z",
  "finishedAt": "$finished_at",
  "durationMs": $duration_ms,
  "humanInterventions": 0,
  "notes": "$notes",
  "tokenUsage": {
    "prompt": 100,
    "completion": 20,
    "retry": 0,
    "debug": 0,
    "total": $total_tokens
  },
  "harnessUsage": {
    "provider": "$harness",
    "agentLogFile": "/tmp/$harness-run.jsonl",
    "inputTokens": 100,
    "cachedInputTokens": 10,
    "outputTokens": 20,
    "uncachedInputTokens": 90,
    "uncachedTotal": $uncached_total
  },
  "verification": {
    "passed": $passed,
    "command": ["bash", "scripts/verify.sh"],
    "exitCode": $exit_code
  }
}
EOF
}

write_result "2026-03-01T10-01-00.000Z--clasp-lead-segment--codex.json" "clasp-lead-segment" "clasp" "codex" "gpt-5.4" "remediation-a-1" "2026-03-01T10:01:00.000Z" 100 120 110 false 1
write_result "2026-03-01T10-02-00.000Z--clasp-lead-segment--codex.json" "clasp-lead-segment" "clasp" "codex" "gpt-5.4" "remediation-a-2" "2026-03-01T10:02:00.000Z" 200 130 120 true 0
write_result "2026-03-01T10-03-00.000Z--ts-lead-segment--codex.json" "ts-lead-segment" "typescript" "codex" "gpt-5.4" "remediation-a-1" "2026-03-01T10:03:00.000Z" 150 140 130 true 0
write_result "2026-03-01T10-04-00.000Z--ts-lead-segment--codex.json" "ts-lead-segment" "typescript" "codex" "gpt-5.4" "remediation-a-2" "2026-03-01T10:04:00.000Z" 180 160 150 true 0
write_result "2026-03-01T10-05-00.000Z--clasp-lead-priority--codex.json" "clasp-lead-priority" "clasp" "codex" "gpt-5.4" "priority-a-1" "2026-03-01T10:05:00.000Z" 220 180 150 true 0
write_result "2026-03-01T10-06-00.000Z--clasp-lead-priority--codex.json" "clasp-lead-priority" "clasp" "codex" "gpt-5.4" "priority-a-2" "2026-03-01T10:06:00.000Z" 160 150 120 true 0
write_result "2026-03-01T10-07-00.000Z--ts-lead-priority--codex.json" "ts-lead-priority" "typescript" "codex" "gpt-5.4" "priority-a-1" "2026-03-01T10:07:00.000Z" 200 170 140 false 1
write_result "2026-03-01T10-08-00.000Z--ts-lead-priority--codex.json" "ts-lead-priority" "typescript" "codex" "gpt-5.4" "priority-a-2" "2026-03-01T10:08:00.000Z" 210 165 135 true 0
write_result "2026-03-01T10-09-00.000Z--clasp-lead-priority--claude-code.json" "clasp-lead-priority" "clasp" "claude-code" "sonnet" "claude-a-1" "2026-03-01T10:09:00.000Z" 190 175 140 true 0
write_result "2026-03-01T10-10-00.000Z--ts-lead-priority--claude-code.json" "ts-lead-priority" "typescript" "claude-code" "sonnet" "claude-a-1" "2026-03-01T10:10:00.000Z" 230 210 190 false 1
write_result "2026-03-01T10-10-30.000Z--clasp-lead-rejection--codex.json" "clasp-lead-rejection" "clasp" "codex" "gpt-5.4" "rejection-a-1" "2026-03-01T10:10:30.000Z" 140 135 110 false 1
write_result "2026-03-01T10-10-45.000Z--clasp-lead-rejection--codex.json" "clasp-lead-rejection" "clasp" "codex" "gpt-5.4" "rejection-a-2" "2026-03-01T10:10:45.000Z" 120 125 100 true 0
write_result "2026-03-01T10-10-50.000Z--ts-lead-rejection--codex.json" "ts-lead-rejection" "typescript" "codex" "gpt-5.4" "rejection-a-1" "2026-03-01T10:10:50.000Z" 160 150 130 false 1
write_result "2026-03-01T10-10-55.000Z--ts-lead-rejection--codex.json" "ts-lead-rejection" "typescript" "codex" "gpt-5.4" "rejection-a-2" "2026-03-01T10:10:55.000Z" 170 155 135 true 0
write_result "2026-03-01T10-10-56.000Z--clasp-control-plane--codex.json" "clasp-control-plane" "clasp" "codex" "gpt-5.4" "containment-a-1" "2026-03-01T10:10:56.000Z" 130 145 120 false 1
write_result "2026-03-01T10-10-57.000Z--clasp-control-plane--codex.json" "clasp-control-plane" "clasp" "codex" "gpt-5.4" "containment-a-2" "2026-03-01T10:10:57.000Z" 90 120 95 true 0
write_result "2026-03-01T10-10-58.000Z--ts-control-plane--codex.json" "ts-control-plane" "typescript" "codex" "gpt-5.4" "containment-a-1" "2026-03-01T10:10:58.000Z" 150 165 145 false 1
write_result "2026-03-01T10-10-59.000Z--ts-control-plane--codex.json" "ts-control-plane" "typescript" "codex" "gpt-5.4" "containment-a-2" "2026-03-01T10:10:59.000Z" 170 170 150 false 1
write_result "2026-03-01T10-11-01.000Z--clasp-lead-priority--codex.json" "clasp-lead-priority" "clasp" "codex" "gpt-5.4" "public-app-1" "2026-03-01T10:11:01.000Z" 180 160 150 true 0
write_result "2026-03-01T10-11-02.000Z--ts-lead-priority--codex.json" "ts-lead-priority" "typescript" "codex" "gpt-5.4" "public-app-1" "2026-03-01T10:11:02.000Z" 220 190 170 true 0
write_result "2026-03-01T10-11-03.000Z--clasp-lead-rejection--codex.json" "clasp-lead-rejection" "clasp" "codex" "gpt-5.4" "public-app-1" "2026-03-01T10:11:03.000Z" 140 120 100 true 0
write_result "2026-03-01T10-11-04.000Z--ts-lead-rejection--codex.json" "ts-lead-rejection" "typescript" "codex" "gpt-5.4" "public-app-1" "2026-03-01T10:11:04.000Z" 200 145 130 true 0
write_result "2026-03-01T10-11-05.000Z--clasp-lead-segment--codex.json" "clasp-lead-segment" "clasp" "codex" "gpt-5.4" "public-app-1" "2026-03-01T10:11:05.000Z" 160 130 120 true 0
write_result "2026-03-01T10-11-06.000Z--ts-lead-segment--codex.json" "ts-lead-segment" "typescript" "codex" "gpt-5.4" "public-app-1" "2026-03-01T10:11:06.000Z" 210 155 140 true 0
write_result "2026-03-01T10-11-00.000Z--py-agent-escalation--codex.json" "py-agent-escalation" "python" "codex" "gpt-5.4" "py-escalation-1" "2026-03-01T10:11:00.000Z" 90 115 100 false 1
write_result "2026-03-01T10-12-00.000Z--py-agent-escalation--codex.json" "py-agent-escalation" "python" "codex" "gpt-5.4" "py-escalation-2" "2026-03-01T10:12:00.000Z" 110 125 105 true 0
write_result "2026-03-01T10-12-05.000Z--clasp-syntax-compact--codex.json" "clasp-syntax-compact" "clasp" "codex" "gpt-5.4" "syntax-a-1" "2026-03-01T10:12:05.000Z" 80 90 82 true 0
write_result "2026-03-01T10-12-10.000Z--clasp-syntax-compact--codex.json" "clasp-syntax-compact" "clasp" "codex" "gpt-5.4" "syntax-a-2" "2026-03-01T10:12:10.000Z" 70 88 80 true 0
write_result "2026-03-01T10-12-15.000Z--clasp-syntax-verbose--codex.json" "clasp-syntax-verbose" "clasp" "codex" "gpt-5.4" "syntax-a-1" "2026-03-01T10:12:15.000Z" 100 120 108 false 1
write_result "2026-03-01T10-12-20.000Z--clasp-syntax-verbose--codex.json" "clasp-syntax-verbose" "clasp" "codex" "gpt-5.4" "syntax-a-2" "2026-03-01T10:12:20.000Z" 110 130 118 true 0

durable_result_path="$results_root/2026-03-01T10-12-30.000Z--clasp-durable-workflow--scenario.json"
synthetic_files+=("$durable_result_path")
cat >"$durable_result_path" <<EOF
{
  "taskId": "clasp-durable-workflow",
  "suite": "durable-workflow",
  "language": "clasp",
  "harness": "scenario",
  "model": "deterministic",
  "startedAt": "2026-03-01T10:12:00.000Z",
  "finishedAt": "2026-03-01T10:12:30.000Z",
  "durationMs": 784,
  "humanInterventions": 0,
  "notes": "durable-a-1",
  "tokenUsage": {
    "prompt": 0,
    "completion": 0,
    "retry": 0,
    "debug": 0,
    "total": 0
  },
  "verification": {
    "passed": true,
    "command": ["bash", "scripts/verify.sh"],
    "exitCode": 0
  }
}
EOF

summary_output="$(node "$project_root/benchmarks/run-benchmark.mjs" summarize --harness codex --model gpt-5.4 --notes remediation-a)"
printf '%s\n' "$summary_output" | grep -Fq $'clasp-lead-segment\tcodex\tgpt-5.4'
printf '%s\n' "$summary_output" | grep -Fq '  series: remediation-a'
printf '%s\n' "$summary_output" | grep -Fq '  passRate: 50%'
printf '%s\n' "$summary_output" | grep -Fq '  timeToGreenMs: 300'
printf '%s\n' "$summary_output" | grep -Fq $'ts-lead-segment\tcodex\tgpt-5.4'
printf '%s\n' "$summary_output" | grep -Fq '  passRate: 100%'
printf '%s\n' "$summary_output" | grep -Fq '  timeToGreenMs: 150'
printf '%s\n' "$summary_output" | grep -Fq 'lead-segment-comparison'
printf '%s\n' "$summary_output" | grep -Fq $'  codex\tgpt-5.4\tremediation-a'
printf '%s\n' "$summary_output" | grep -Fq '    passRateDeltaPct: -50'
printf '%s\n' "$summary_output" | grep -Fq '    timeToGreenDeltaMs: 150'
printf '%s\n' "$summary_output" | grep -Fq '    tokenDelta: -25'
printf '%s\n' "$summary_output" | grep -Fq '    uncachedTokenDelta: -25'

priority_summary_output="$(node "$project_root/benchmarks/run-benchmark.mjs" summarize --harness codex --model gpt-5.4 --notes priority-a)"
printf '%s\n' "$priority_summary_output" | grep -Fq $'clasp-lead-priority\tcodex\tgpt-5.4'
printf '%s\n' "$priority_summary_output" | grep -Fq $'ts-lead-priority\tcodex\tgpt-5.4'
printf '%s\n' "$priority_summary_output" | grep -Fq 'lead-priority-comparison'
printf '%s\n' "$priority_summary_output" | grep -Fq $'  codex\tgpt-5.4\tpriority-a'
printf '%s\n' "$priority_summary_output" | grep -Fq '    claspPassRate: 100%'
printf '%s\n' "$priority_summary_output" | grep -Fq '    tsPassRate: 50%'
printf '%s\n' "$priority_summary_output" | grep -Fq '    passRateDeltaPct: 50'
printf '%s\n' "$priority_summary_output" | grep -Fq '    timeToGreenDeltaMs: -190'
printf '%s\n' "$priority_summary_output" | grep -Fq '    tokenDelta: -3'
printf '%s\n' "$priority_summary_output" | grep -Fq '    uncachedTokenDelta: -3'

rejection_summary_output="$(node "$project_root/benchmarks/run-benchmark.mjs" summarize --harness codex --model gpt-5.4 --notes rejection-a)"
printf '%s\n' "$rejection_summary_output" | grep -Fq $'clasp-lead-rejection\tcodex\tgpt-5.4'
printf '%s\n' "$rejection_summary_output" | grep -Fq $'ts-lead-rejection\tcodex\tgpt-5.4'
printf '%s\n' "$rejection_summary_output" | grep -Fq 'lead-rejection-comparison'
printf '%s\n' "$rejection_summary_output" | grep -Fq $'  codex\tgpt-5.4\trejection-a'
printf '%s\n' "$rejection_summary_output" | grep -Fq '    claspPassRate: 50%'
printf '%s\n' "$rejection_summary_output" | grep -Fq '    tsPassRate: 50%'
printf '%s\n' "$rejection_summary_output" | grep -Fq '    passRateDeltaPct: 0'
printf '%s\n' "$rejection_summary_output" | grep -Fq '    timeToGreenDeltaMs: -70'
printf '%s\n' "$rejection_summary_output" | grep -Fq '    tokenDelta: -23'
printf '%s\n' "$rejection_summary_output" | grep -Fq '    uncachedTokenDelta: -28'

containment_summary_output="$(node "$project_root/benchmarks/run-benchmark.mjs" summarize --harness codex --model gpt-5.4 --notes containment-a)"
printf '%s\n' "$containment_summary_output" | grep -Fq $'clasp-control-plane\tcodex\tgpt-5.4'
printf '%s\n' "$containment_summary_output" | grep -Fq $'ts-control-plane\tcodex\tgpt-5.4'
printf '%s\n' "$containment_summary_output" | grep -Fq 'control-plane-comparison'
printf '%s\n' "$containment_summary_output" | grep -Fq $'  codex\tgpt-5.4\tcontainment-a'
printf '%s\n' "$containment_summary_output" | grep -Fq '    claspPassRate: 50%'
printf '%s\n' "$containment_summary_output" | grep -Fq '    tsPassRate: 0%'
printf '%s\n' "$containment_summary_output" | grep -Fq '    passRateDeltaPct: 50'
printf '%s\n' "$containment_summary_output" | grep -Fq '    timeToGreenDeltaMs: n/a'
printf '%s\n' "$containment_summary_output" | grep -Fq '    tokenDelta: -35'
printf '%s\n' "$containment_summary_output" | grep -Fq '    uncachedTokenDelta: -40'

python_summary_output="$(node "$project_root/benchmarks/run-benchmark.mjs" summarize --harness codex --model gpt-5.4 --notes py-escalation)"
printf '%s\n' "$python_summary_output" | grep -Fq $'py-agent-escalation\tcodex\tgpt-5.4'
printf '%s\n' "$python_summary_output" | grep -Fq '  series: py-escalation'
printf '%s\n' "$python_summary_output" | grep -Fq '  runs: 2'
printf '%s\n' "$python_summary_output" | grep -Fq '  passRate: 50%'
printf '%s\n' "$python_summary_output" | grep -Fq '  timeToGreenMs: 200'
printf '%s\n' "$python_summary_output" | grep -Fq '  medianDurationMs: 100'
printf '%s\n' "$python_summary_output" | grep -Fq '  medianTokens: 120'
printf '%s\n' "$python_summary_output" | grep -Fq '  medianUncachedTokens: 103'

syntax_summary_output="$(node "$project_root/benchmarks/run-benchmark.mjs" summarize --harness codex --model gpt-5.4 --notes syntax-a)"
printf '%s\n' "$syntax_summary_output" | grep -Fq $'clasp-syntax-compact\tcodex\tgpt-5.4'
printf '%s\n' "$syntax_summary_output" | grep -Fq $'clasp-syntax-verbose\tcodex\tgpt-5.4'
printf '%s\n' "$syntax_summary_output" | grep -Fq '  series: syntax-a'
printf '%s\n' "$syntax_summary_output" | grep -Fq 'syntax-form-comparison'
printf '%s\n' "$syntax_summary_output" | grep -Fq $'  codex\tgpt-5.4\tsyntax-a'
printf '%s\n' "$syntax_summary_output" | grep -Fq '    compactPassRate: 100%'
printf '%s\n' "$syntax_summary_output" | grep -Fq '    verbosePassRate: 50%'
printf '%s\n' "$syntax_summary_output" | grep -Fq '    passRateDeltaPct: 50'
printf '%s\n' "$syntax_summary_output" | grep -Fq '    compactTimeToGreenMs: 80'
printf '%s\n' "$syntax_summary_output" | grep -Fq '    verboseTimeToGreenMs: 210'
printf '%s\n' "$syntax_summary_output" | grep -Fq '    timeToGreenDeltaMs: -130'
printf '%s\n' "$syntax_summary_output" | grep -Fq '    compactMedianTokens: 89'
printf '%s\n' "$syntax_summary_output" | grep -Fq '    verboseMedianTokens: 125'
printf '%s\n' "$syntax_summary_output" | grep -Fq '    tokenDelta: -36'
printf '%s\n' "$syntax_summary_output" | grep -Fq '    uncachedTokenDelta: -32'

public_app_summary_output="$(node "$project_root/benchmarks/run-benchmark.mjs" summarize --harness codex --model gpt-5.4 --notes public-app)"
printf '%s\n' "$public_app_summary_output" | grep -Fq 'main-public-app-comparison'
printf '%s\n' "$public_app_summary_output" | grep -Fq $'  codex\tgpt-5.4\tpublic-app'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    taskPairs: 3'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    claspCompletedTasks: 3/3'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    tsCompletedTasks: 3/3'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    claspRunPassRate: 100%'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    tsRunPassRate: 100%'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    passRateDeltaPct: 0'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    claspSuiteTimeToGreenMs: 480'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    tsSuiteTimeToGreenMs: 630'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    timeToGreenDeltaMs: -150'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    claspSuiteMedianTokens: 410'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    tsSuiteMedianTokens: 490'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    tokenDelta: -80'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    uncachedTokenDelta: -70'

durable_workflow_summary_output="$(
  node "$project_root/benchmarks/run-benchmark.mjs" summarize \
    --task-id clasp-durable-workflow \
    --harness scenario \
    --model deterministic
)"
printf '%s\n' "$durable_workflow_summary_output" | grep -Fq $'clasp-durable-workflow\tscenario\tdeterministic'
printf '%s\n' "$durable_workflow_summary_output" | grep -Fq '  runs: 1'
printf '%s\n' "$durable_workflow_summary_output" | grep -Fq '  passRate: 100%'
printf '%s\n' "$durable_workflow_summary_output" | grep -Fq '  timeToGreenMs: 784'
printf '%s\n' "$durable_workflow_summary_output" | grep -Fq '  medianDurationMs: 784'
printf '%s\n' "$durable_workflow_summary_output" | grep -Fq '  medianTokens: 0'
printf '%s\n' "$durable_workflow_summary_output" | grep -Fq '  medianUncachedTokens: 0'

cat >"$tmp_bin/nix" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$tmp_bin/nix.log"
EOF
chmod +x "$tmp_bin/nix"

PATH="$tmp_bin:$PATH" bash "$project_root/benchmarks/run-codex-series.sh" lead-segment 2 remediation-a gpt-5.4
command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$command_log" | grep -Fq 'run clasp-lead-segment'
printf '%s\n' "$command_log" | grep -Fq 'run ts-lead-segment'
printf '%s\n' "$command_log" | grep -Fq -- '--notes remediation-a-1'
printf '%s\n' "$command_log" | grep -Fq -- '--notes remediation-a-2'

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" bash "$project_root/benchmarks/run-codex-series.sh" control-plane 2 containment-a gpt-5.4
control_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$control_command_log" | grep -Fq 'run clasp-control-plane'
printf '%s\n' "$control_command_log" | grep -Fq 'run ts-control-plane'
printf '%s\n' "$control_command_log" | grep -Fq -- '--notes containment-a-1'
printf '%s\n' "$control_command_log" | grep -Fq -- '--notes containment-a-2'

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" bash "$project_root/benchmarks/run-codex-series.sh" lead-priority 2 priority-a gpt-5.4
priority_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$priority_command_log" | grep -Fq 'run clasp-lead-priority'
printf '%s\n' "$priority_command_log" | grep -Fq 'run ts-lead-priority'
printf '%s\n' "$priority_command_log" | grep -Fq -- '--notes priority-a-1'
printf '%s\n' "$priority_command_log" | grep -Fq -- '--notes priority-a-2'

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" bash "$project_root/benchmarks/run-codex-series.sh" lead-rejection 2 rejection-a gpt-5.4
rejection_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$rejection_command_log" | grep -Fq 'run clasp-lead-rejection'
printf '%s\n' "$rejection_command_log" | grep -Fq 'run ts-lead-rejection'
printf '%s\n' "$rejection_command_log" | grep -Fq -- '--notes rejection-a-1'
printf '%s\n' "$rejection_command_log" | grep -Fq -- '--notes rejection-a-2'

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" bash "$project_root/benchmarks/run-codex-series.sh" syntax-form 2 syntax-a gpt-5.4
syntax_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$syntax_command_log" | grep -Fq 'run clasp-syntax-compact'
printf '%s\n' "$syntax_command_log" | grep -Fq 'run clasp-syntax-verbose'
printf '%s\n' "$syntax_command_log" | grep -Fq -- '--notes syntax-a-1'
printf '%s\n' "$syntax_command_log" | grep -Fq -- '--notes syntax-a-2'

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" bash "$project_root/benchmarks/run-codex-series.sh" app 2 public-app gpt-5.4
app_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$app_command_log" | grep -Fq 'run clasp-lead-priority'
printf '%s\n' "$app_command_log" | grep -Fq 'run ts-lead-priority'
printf '%s\n' "$app_command_log" | grep -Fq 'run clasp-lead-rejection'
printf '%s\n' "$app_command_log" | grep -Fq 'run ts-lead-rejection'
printf '%s\n' "$app_command_log" | grep -Fq 'run clasp-lead-segment'
printf '%s\n' "$app_command_log" | grep -Fq 'run ts-lead-segment'
printf '%s\n' "$app_command_log" | grep -Fq -- '--notes public-app-1'
printf '%s\n' "$app_command_log" | grep -Fq -- '--notes public-app-2'

claude_summary_output="$(node "$project_root/benchmarks/run-benchmark.mjs" summarize --harness claude-code --model sonnet --notes claude-a)"
printf '%s\n' "$claude_summary_output" | grep -Fq $'clasp-lead-priority\tclaude-code\tsonnet'
printf '%s\n' "$claude_summary_output" | grep -Fq $'ts-lead-priority\tclaude-code\tsonnet'
printf '%s\n' "$claude_summary_output" | grep -Fq 'lead-priority-comparison'
printf '%s\n' "$claude_summary_output" | grep -Fq $'  claude-code\tsonnet\tclaude-a'
printf '%s\n' "$claude_summary_output" | grep -Fq '    claspPassRate: 100%'
printf '%s\n' "$claude_summary_output" | grep -Fq '    tsPassRate: 0%'
printf '%s\n' "$claude_summary_output" | grep -Fq '    passRateDeltaPct: 100'
printf '%s\n' "$claude_summary_output" | grep -Fq '    timeToGreenDeltaMs: n/a'
printf '%s\n' "$claude_summary_output" | grep -Fq '    tokenDelta: -35'
printf '%s\n' "$claude_summary_output" | grep -Fq '    uncachedTokenDelta: -50'

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" bash "$project_root/benchmarks/run-claude-series.sh" lead-priority 2 claude-a sonnet
claude_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$claude_command_log" | grep -Fq 'run clasp-lead-priority'
printf '%s\n' "$claude_command_log" | grep -Fq 'run ts-lead-priority'
printf '%s\n' "$claude_command_log" | grep -Fq -- '--harness claude-code'
printf '%s\n' "$claude_command_log" | grep -Fq -- '--model sonnet'
printf '%s\n' "$claude_command_log" | grep -Fq -- '--notes claude-a-1'
printf '%s\n' "$claude_command_log" | grep -Fq -- '--notes claude-a-2'

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" bash "$project_root/benchmarks/run-claude-series.sh" syntax-form 2 syntax-a sonnet
claude_syntax_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$claude_syntax_command_log" | grep -Fq 'run clasp-syntax-compact'
printf '%s\n' "$claude_syntax_command_log" | grep -Fq 'run clasp-syntax-verbose'
printf '%s\n' "$claude_syntax_command_log" | grep -Fq -- '--harness claude-code'
printf '%s\n' "$claude_syntax_command_log" | grep -Fq -- '--model sonnet'
printf '%s\n' "$claude_syntax_command_log" | grep -Fq -- '--notes syntax-a-1'
printf '%s\n' "$claude_syntax_command_log" | grep -Fq -- '--notes syntax-a-2'

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" bash "$project_root/benchmarks/run-claude-series.sh" app 2 public-app sonnet
claude_app_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$claude_app_command_log" | grep -Fq 'run clasp-lead-priority'
printf '%s\n' "$claude_app_command_log" | grep -Fq 'run ts-lead-priority'
printf '%s\n' "$claude_app_command_log" | grep -Fq 'run clasp-lead-rejection'
printf '%s\n' "$claude_app_command_log" | grep -Fq 'run ts-lead-rejection'
printf '%s\n' "$claude_app_command_log" | grep -Fq 'run clasp-lead-segment'
printf '%s\n' "$claude_app_command_log" | grep -Fq 'run ts-lead-segment'
printf '%s\n' "$claude_app_command_log" | grep -Fq -- '--harness claude-code'
printf '%s\n' "$claude_app_command_log" | grep -Fq -- '--model sonnet'
printf '%s\n' "$claude_app_command_log" | grep -Fq -- '--notes public-app-1'
printf '%s\n' "$claude_app_command_log" | grep -Fq -- '--notes public-app-2'

claude_workspace="$project_root/benchmarks/workspaces/claude-usage-check"
rm -rf "$claude_workspace"
node "$project_root/benchmarks/run-benchmark.mjs" prepare clasp-lead-segment --workspace "$claude_workspace" >/dev/null
cp "$project_root/examples/lead-app/Shared/Lead.clasp" "$claude_workspace/Shared/Lead.clasp"

cat >"$claude_workspace/claude-run.jsonl" <<EOF
{"type":"assistant","message":{"usage":{"input_tokens":40,"cache_creation_input_tokens":5,"cache_read_input_tokens":10,"output_tokens":12}}}
{"type":"assistant","message":{"usage":{"input_tokens":30,"cache_creation_input_tokens":0,"cache_read_input_tokens":20,"output_tokens":8}}}
{"type":"result","subtype":"success","duration_ms":250}
EOF

node "$project_root/benchmarks/run-benchmark.mjs" verify clasp-lead-segment \
  --workspace "$claude_workspace" \
  --harness claude-code \
  --model sonnet \
  --notes claude-usage-check >/dev/null

latest_result=""
latest_result_mtime=0
for candidate in "$results_root"/*.json; do
  [[ -e "$candidate" ]] || continue
  candidate_mtime="$(stat -c '%Y' "$candidate")"
  if [[ -z "$latest_result" || "$candidate_mtime" -gt "$latest_result_mtime" ]]; then
    latest_result="$candidate"
    latest_result_mtime="$candidate_mtime"
  fi
done

if [[ -z "$latest_result" ]]; then
  echo "expected at least one benchmark result artifact" >&2
  exit 1
fi

synthetic_files+=("$latest_result")
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"harness": "claude-code"'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"model": "sonnet"'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"prompt": 105'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"completion": 20'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"total": 125'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"cachedInputTokens": 30'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"uncachedInputTokens": 75'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"uncachedTotal": 95'
