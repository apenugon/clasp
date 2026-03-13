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
PATH="$tmp_bin:$PATH" bash "$project_root/benchmarks/run-codex-series.sh" lead-priority 2 priority-a gpt-5.4
priority_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$priority_command_log" | grep -Fq 'run clasp-lead-priority'
printf '%s\n' "$priority_command_log" | grep -Fq 'run ts-lead-priority'
printf '%s\n' "$priority_command_log" | grep -Fq -- '--notes priority-a-1'
printf '%s\n' "$priority_command_log" | grep -Fq -- '--notes priority-a-2'

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

latest_result="$(ls -1t "$results_root"/*.json | head -n1)"
synthetic_files+=("$latest_result")
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"harness": "claude-code"'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"model": "sonnet"'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"prompt": 105'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"completion": 20'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"total": 125'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"cachedInputTokens": 30'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"uncachedInputTokens": 75'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"uncachedTotal": 95'
