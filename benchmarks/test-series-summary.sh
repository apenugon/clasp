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
  local notes="$4"
  local finished_at="$5"
  local duration_ms="$6"
  local total_tokens="$7"
  local uncached_total="$8"
  local passed="$9"
  local exit_code="${10}"
  local result_path="$results_root/$filename"

  synthetic_files+=("$result_path")

  cat >"$result_path" <<EOF
{
  "taskId": "$task_id",
  "suite": "clickable-lead-inbox",
  "language": "$language",
  "harness": "codex",
  "model": "gpt-5.4",
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
    "provider": "codex",
    "agentLogFile": "/tmp/codex-run.jsonl",
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

write_result "2026-03-01T10-01-00.000Z--clasp-lead-segment--codex.json" "clasp-lead-segment" "clasp" "remediation-a-1" "2026-03-01T10:01:00.000Z" 100 120 110 false 1
write_result "2026-03-01T10-02-00.000Z--clasp-lead-segment--codex.json" "clasp-lead-segment" "clasp" "remediation-a-2" "2026-03-01T10:02:00.000Z" 200 130 120 true 0
write_result "2026-03-01T10-03-00.000Z--ts-lead-segment--codex.json" "ts-lead-segment" "typescript" "remediation-a-1" "2026-03-01T10:03:00.000Z" 150 140 130 true 0
write_result "2026-03-01T10-04-00.000Z--ts-lead-segment--codex.json" "ts-lead-segment" "typescript" "remediation-a-2" "2026-03-01T10:04:00.000Z" 180 160 150 true 0

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
