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
  local sample_index=""
  if [[ "$notes" =~ -([0-9]+)$ ]]; then
    sample_index="${BASH_REMATCH[1]}"
  fi

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
  "protocol": {
    "schemaVersion": 1,
    "mode": "raw-repo",
    "promptFile": "benchmarks/tasks/$task_id/prompt.raw.md",
    "repeatedSamples": 2,
    "sampleIndex": ${sample_index:-null},
    "runOrderPosition": ${sample_index:-null},
    "randomizedOrderSeed": "${notes%-$sample_index}:seed",
    "bundle": null,
    "timingWindow": {
      "startedAt": "2026-03-01T10:00:00.000Z",
      "finishedAt": "$finished_at"
    }
  },
  "phases": {
    "discoveryMs": $((duration_ms / 5)),
    "firstEditMs": $((duration_ms / 2)),
    "firstVerifyMs": $(((duration_ms * 4) / 5)),
    "timeToGreenMs": $duration_ms
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
write_result "2026-03-01T10-11-10.000Z--clasp-external-adaptation--codex.json" "clasp-external-adaptation" "clasp" "codex" "gpt-5.4" "objective-a-1" "2026-03-01T10:11:10.000Z" 90 150 130 false 1
write_result "2026-03-01T10-11-11.000Z--clasp-external-adaptation--codex.json" "clasp-external-adaptation" "clasp" "codex" "gpt-5.4" "objective-a-2" "2026-03-01T10:11:11.000Z" 110 140 120 true 0
write_result "2026-03-01T10-11-12.000Z--ts-external-adaptation--codex.json" "ts-external-adaptation" "typescript" "codex" "gpt-5.4" "objective-a-1" "2026-03-01T10:11:12.000Z" 100 155 135 true 0
write_result "2026-03-01T10-11-13.000Z--ts-external-adaptation--codex.json" "ts-external-adaptation" "typescript" "codex" "gpt-5.4" "objective-a-2" "2026-03-01T10:11:13.000Z" 120 165 145 true 0
write_result "2026-03-01T10-11-01.000Z--clasp-lead-priority--codex.json" "clasp-lead-priority" "clasp" "codex" "gpt-5.4" "public-app-1" "2026-03-01T10:11:01.000Z" 180000 160 150 true 0
write_result "2026-03-01T10-11-02.000Z--ts-lead-priority--codex.json" "ts-lead-priority" "typescript" "codex" "gpt-5.4" "public-app-1" "2026-03-01T10:11:02.000Z" 220000 190 170 true 0
write_result "2026-03-01T10-11-03.000Z--clasp-lead-rejection--codex.json" "clasp-lead-rejection" "clasp" "codex" "gpt-5.4" "public-app-1" "2026-03-01T10:11:03.000Z" 140000 120 100 true 0
write_result "2026-03-01T10-11-04.000Z--ts-lead-rejection--codex.json" "ts-lead-rejection" "typescript" "codex" "gpt-5.4" "public-app-1" "2026-03-01T10:11:04.000Z" 200000 145 130 true 0
write_result "2026-03-01T10-11-05.000Z--clasp-lead-segment--codex.json" "clasp-lead-segment" "clasp" "codex" "gpt-5.4" "public-app-1" "2026-03-01T10:11:05.000Z" 160000 130 120 true 0
write_result "2026-03-01T10-11-06.000Z--ts-lead-segment--codex.json" "ts-lead-segment" "typescript" "codex" "gpt-5.4" "public-app-1" "2026-03-01T10:11:06.000Z" 210000 155 140 true 0
write_result "2026-03-01T10-11-07.000Z--clasp-external-adaptation--codex.json" "clasp-external-adaptation" "clasp" "codex" "gpt-5.4" "public-app-1" "2026-03-01T10:11:07.000Z" 150000 140 130 true 0
write_result "2026-03-01T10-11-08.000Z--ts-external-adaptation--codex.json" "ts-external-adaptation" "typescript" "codex" "gpt-5.4" "public-app-1" "2026-03-01T10:11:08.000Z" 240000 175 160 true 0
write_result "2026-03-01T10-11-00.000Z--py-agent-escalation--codex.json" "py-agent-escalation" "python" "codex" "gpt-5.4" "py-escalation-1" "2026-03-01T10:11:00.000Z" 90 115 100 false 1
write_result "2026-03-01T10-12-00.000Z--py-agent-escalation--codex.json" "py-agent-escalation" "python" "codex" "gpt-5.4" "py-escalation-2" "2026-03-01T10:12:00.000Z" 110 125 105 true 0
write_result "2026-03-01T10-12-05.000Z--clasp-syntax-compact--codex.json" "clasp-syntax-compact" "clasp" "codex" "gpt-5.4" "syntax-a-1" "2026-03-01T10:12:05.000Z" 80 90 82 true 0
write_result "2026-03-01T10-12-10.000Z--clasp-syntax-compact--codex.json" "clasp-syntax-compact" "clasp" "codex" "gpt-5.4" "syntax-a-2" "2026-03-01T10:12:10.000Z" 70 88 80 true 0
write_result "2026-03-01T10-12-15.000Z--clasp-syntax-verbose--codex.json" "clasp-syntax-verbose" "clasp" "codex" "gpt-5.4" "syntax-a-1" "2026-03-01T10:12:15.000Z" 100 120 108 false 1
write_result "2026-03-01T10-12-20.000Z--clasp-syntax-verbose--codex.json" "clasp-syntax-verbose" "clasp" "codex" "gpt-5.4" "syntax-a-2" "2026-03-01T10:12:20.000Z" 110 130 118 true 0
write_result "2026-03-01T10-12-25.000Z--clasp-compiler-maintenance--codex.json" "clasp-compiler-maintenance" "clasp" "codex" "gpt-5.4" "compiler-a-1" "2026-03-01T10:12:25.000Z" 260 180 150 false 1
write_result "2026-03-01T10-12-26.000Z--clasp-compiler-maintenance--codex.json" "clasp-compiler-maintenance" "clasp" "codex" "gpt-5.4" "compiler-a-2" "2026-03-01T10:12:26.000Z" 220 170 140 true 0
write_result "2026-03-01T10-12-31.000Z--clasp-npm-interop--codex.json" "clasp-npm-interop" "clasp" "codex" "gpt-5.4" "interop-a-1" "2026-03-01T10:12:31.000Z" 70 95 88 true 0
write_result "2026-03-01T10-12-32.000Z--clasp-npm-interop--codex.json" "clasp-npm-interop" "clasp" "codex" "gpt-5.4" "interop-a-2" "2026-03-01T10:12:32.000Z" 80 100 92 true 0
write_result "2026-03-01T10-12-33.000Z--ts-npm-interop--codex.json" "ts-npm-interop" "typescript" "codex" "gpt-5.4" "interop-a-1" "2026-03-01T10:12:33.000Z" 100 130 120 false 1
write_result "2026-03-01T10-12-34.000Z--ts-npm-interop--codex.json" "ts-npm-interop" "typescript" "codex" "gpt-5.4" "interop-a-2" "2026-03-01T10:12:34.000Z" 110 140 126 true 0
write_result "2026-03-01T10-12-35.000Z--clasp-python-interop--codex.json" "clasp-python-interop" "clasp" "codex" "gpt-5.4" "interop-a-1" "2026-03-01T10:12:35.000Z" 120 150 135 false 1
write_result "2026-03-01T10-12-36.000Z--clasp-python-interop--codex.json" "clasp-python-interop" "clasp" "codex" "gpt-5.4" "interop-a-2" "2026-03-01T10:12:36.000Z" 90 140 125 true 0
write_result "2026-03-01T10-12-37.000Z--ts-python-interop--codex.json" "ts-python-interop" "typescript" "codex" "gpt-5.4" "interop-a-1" "2026-03-01T10:12:37.000Z" 160 200 180 false 1
write_result "2026-03-01T10-12-38.000Z--ts-python-interop--codex.json" "ts-python-interop" "typescript" "codex" "gpt-5.4" "interop-a-2" "2026-03-01T10:12:38.000Z" 180 210 190 true 0
write_result "2026-03-01T10-12-39.000Z--clasp-rust-interop--codex.json" "clasp-rust-interop" "clasp" "codex" "gpt-5.4" "interop-a-1" "2026-03-01T10:12:39.000Z" 75 115 105 true 0
write_result "2026-03-01T10-12-40.000Z--clasp-rust-interop--codex.json" "clasp-rust-interop" "clasp" "codex" "gpt-5.4" "interop-a-2" "2026-03-01T10:12:40.000Z" 85 120 110 true 0
write_result "2026-03-01T10-12-41.000Z--ts-rust-interop--codex.json" "ts-rust-interop" "typescript" "codex" "gpt-5.4" "interop-a-1" "2026-03-01T10:12:41.000Z" 140 170 155 true 0
write_result "2026-03-01T10-12-42.000Z--ts-rust-interop--codex.json" "ts-rust-interop" "typescript" "codex" "gpt-5.4" "interop-a-2" "2026-03-01T10:12:42.000Z" 150 180 165 true 0
write_result "2026-03-01T10-12-43.000Z--clasp-interop-boundary--codex.json" "clasp-interop-boundary" "clasp" "codex" "gpt-5.4" "interop-boundary-a-1" "2026-03-01T10:12:43.000Z" 85 105 95 true 0
write_result "2026-03-01T10-12-44.000Z--clasp-interop-boundary--codex.json" "clasp-interop-boundary" "clasp" "codex" "gpt-5.4" "interop-boundary-a-2" "2026-03-01T10:12:44.000Z" 95 110 100 true 0
write_result "2026-03-01T10-12-45.000Z--ts-interop-boundary--codex.json" "ts-interop-boundary" "typescript" "codex" "gpt-5.4" "interop-boundary-a-1" "2026-03-01T10:12:45.000Z" 130 155 142 false 1
write_result "2026-03-01T10-12-46.000Z--ts-interop-boundary--codex.json" "ts-interop-boundary" "typescript" "codex" "gpt-5.4" "interop-boundary-a-2" "2026-03-01T10:12:46.000Z" 140 160 148 true 0
write_result "2026-03-01T10-13-01.000Z--clasp-npm-interop--codex.json" "clasp-npm-interop" "clasp" "codex" "gpt-5.4" "mixed-stack-a-1" "2026-03-01T10:13:01.000Z" 70 95 88 true 0
write_result "2026-03-01T10-13-02.000Z--clasp-npm-interop--codex.json" "clasp-npm-interop" "clasp" "codex" "gpt-5.4" "mixed-stack-a-2" "2026-03-01T10:13:02.000Z" 80 100 92 true 0
write_result "2026-03-01T10-13-03.000Z--ts-npm-interop--codex.json" "ts-npm-interop" "typescript" "codex" "gpt-5.4" "mixed-stack-a-1" "2026-03-01T10:13:03.000Z" 100 130 120 false 1
write_result "2026-03-01T10-13-04.000Z--ts-npm-interop--codex.json" "ts-npm-interop" "typescript" "codex" "gpt-5.4" "mixed-stack-a-2" "2026-03-01T10:13:04.000Z" 110 140 126 true 0
write_result "2026-03-01T10-13-05.000Z--clasp-python-interop--codex.json" "clasp-python-interop" "clasp" "codex" "gpt-5.4" "mixed-stack-a-1" "2026-03-01T10:13:05.000Z" 120 150 135 false 1
write_result "2026-03-01T10-13-06.000Z--clasp-python-interop--codex.json" "clasp-python-interop" "clasp" "codex" "gpt-5.4" "mixed-stack-a-2" "2026-03-01T10:13:06.000Z" 90 140 125 true 0
write_result "2026-03-01T10-13-07.000Z--ts-python-interop--codex.json" "ts-python-interop" "typescript" "codex" "gpt-5.4" "mixed-stack-a-1" "2026-03-01T10:13:07.000Z" 160 200 180 false 1
write_result "2026-03-01T10-13-08.000Z--ts-python-interop--codex.json" "ts-python-interop" "typescript" "codex" "gpt-5.4" "mixed-stack-a-2" "2026-03-01T10:13:08.000Z" 180 210 190 true 0
write_result "2026-03-01T10-13-09.000Z--clasp-rust-interop--codex.json" "clasp-rust-interop" "clasp" "codex" "gpt-5.4" "mixed-stack-a-1" "2026-03-01T10:13:09.000Z" 75 115 105 true 0
write_result "2026-03-01T10-13-10.000Z--clasp-rust-interop--codex.json" "clasp-rust-interop" "clasp" "codex" "gpt-5.4" "mixed-stack-a-2" "2026-03-01T10:13:10.000Z" 85 120 110 true 0
write_result "2026-03-01T10-13-11.000Z--ts-rust-interop--codex.json" "ts-rust-interop" "typescript" "codex" "gpt-5.4" "mixed-stack-a-1" "2026-03-01T10:13:11.000Z" 140 170 155 true 0
write_result "2026-03-01T10-13-12.000Z--ts-rust-interop--codex.json" "ts-rust-interop" "typescript" "codex" "gpt-5.4" "mixed-stack-a-2" "2026-03-01T10:13:12.000Z" 150 180 165 true 0
write_result "2026-03-01T10-13-13.000Z--clasp-interop-boundary--codex.json" "clasp-interop-boundary" "clasp" "codex" "gpt-5.4" "mixed-stack-a-1" "2026-03-01T10:13:13.000Z" 85 105 95 true 0
write_result "2026-03-01T10-13-14.000Z--clasp-interop-boundary--codex.json" "clasp-interop-boundary" "clasp" "codex" "gpt-5.4" "mixed-stack-a-2" "2026-03-01T10:13:14.000Z" 95 110 100 true 0
write_result "2026-03-01T10-13-15.000Z--ts-interop-boundary--codex.json" "ts-interop-boundary" "typescript" "codex" "gpt-5.4" "mixed-stack-a-1" "2026-03-01T10:13:15.000Z" 130 155 142 false 1
write_result "2026-03-01T10-13-16.000Z--ts-interop-boundary--codex.json" "ts-interop-boundary" "typescript" "codex" "gpt-5.4" "mixed-stack-a-2" "2026-03-01T10:13:16.000Z" 140 160 148 true 0
write_result "2026-03-01T10-12-47.000Z--clasp-secret-handling--codex.json" "clasp-secret-handling" "clasp" "codex" "gpt-5.4" "secret-handling-a-1" "2026-03-01T10:12:47.000Z" 80 110 98 true 0
write_result "2026-03-01T10-12-48.000Z--clasp-secret-handling--codex.json" "clasp-secret-handling" "clasp" "codex" "gpt-5.4" "secret-handling-a-2" "2026-03-01T10:12:48.000Z" 90 120 102 true 0
write_result "2026-03-01T10-12-49.000Z--ts-secret-handling--codex.json" "ts-secret-handling" "typescript" "codex" "gpt-5.4" "secret-handling-a-1" "2026-03-01T10:12:49.000Z" 150 170 150 false 1
write_result "2026-03-01T10-12-50.000Z--ts-secret-handling--codex.json" "ts-secret-handling" "typescript" "codex" "gpt-5.4" "secret-handling-a-2" "2026-03-01T10:12:50.000Z" 160 175 155 true 0
write_result "2026-03-01T10-12-51.000Z--clasp-audit-log--codex.json" "clasp-audit-log" "clasp" "codex" "gpt-5.4" "audit-log-a-1" "2026-03-01T10:12:51.000Z" 100 140 120 true 0
write_result "2026-03-01T10-12-52.000Z--clasp-audit-log--codex.json" "clasp-audit-log" "clasp" "codex" "gpt-5.4" "audit-log-a-2" "2026-03-01T10:12:52.000Z" 110 150 130 true 0
write_result "2026-03-01T10-12-53.000Z--ts-audit-log--codex.json" "ts-audit-log" "typescript" "codex" "gpt-5.4" "audit-log-a-1" "2026-03-01T10:12:53.000Z" 190 205 180 false 1
write_result "2026-03-01T10-12-54.000Z--ts-audit-log--codex.json" "ts-audit-log" "typescript" "codex" "gpt-5.4" "audit-log-a-2" "2026-03-01T10:12:54.000Z" 210 215 190 true 0

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
printf '%s\n' "$summary_output" | grep -Fq '  mode: raw-repo'
printf '%s\n' "$summary_output" | grep -Fq '  series: remediation-a'
printf '%s\n' "$summary_output" | grep -Fq '  passRate: 50%'
printf '%s\n' "$summary_output" | grep -Fq '  timeToGreenMs: 300'
printf '%s\n' "$summary_output" | grep -Fq '  medianDiscoveryMs: 30'
printf '%s\n' "$summary_output" | grep -Fq '  medianFirstEditMs: 75'
printf '%s\n' "$summary_output" | grep -Fq '  medianFirstVerifyMs: 120'
printf '%s\n' "$summary_output" | grep -Fq '  medianPhaseTimeToGreenMs: 150'
printf '%s\n' "$summary_output" | grep -Fq $'ts-lead-segment\tcodex\tgpt-5.4'
printf '%s\n' "$summary_output" | grep -Fq '  passRate: 100%'
printf '%s\n' "$summary_output" | grep -Fq '  timeToGreenMs: 150'
printf '%s\n' "$summary_output" | grep -Fq 'lead-segment-comparison'
printf '%s\n' "$summary_output" | grep -Fq $'  codex\tgpt-5.4\tremediation-a'
printf '%s\n' "$summary_output" | grep -Fq '    mode: raw-repo'
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

objective_summary_output="$(node "$project_root/benchmarks/run-benchmark.mjs" summarize --harness codex --model gpt-5.4 --notes objective-a)"
printf '%s\n' "$objective_summary_output" | grep -Fq $'clasp-external-adaptation\tcodex\tgpt-5.4'
printf '%s\n' "$objective_summary_output" | grep -Fq $'ts-external-adaptation\tcodex\tgpt-5.4'
printf '%s\n' "$objective_summary_output" | grep -Fq 'external-adaptation-comparison'
printf '%s\n' "$objective_summary_output" | grep -Fq $'  codex\tgpt-5.4\tobjective-a'
printf '%s\n' "$objective_summary_output" | grep -Fq '    claspPassRate: 50%'
printf '%s\n' "$objective_summary_output" | grep -Fq '    tsPassRate: 100%'
printf '%s\n' "$objective_summary_output" | grep -Fq '    passRateDeltaPct: -50'
printf '%s\n' "$objective_summary_output" | grep -Fq '    timeToGreenDeltaMs: 100'
printf '%s\n' "$objective_summary_output" | grep -Fq '    tokenDelta: -15'
printf '%s\n' "$objective_summary_output" | grep -Fq '    uncachedTokenDelta: -15'

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

compiler_summary_output="$(node "$project_root/benchmarks/run-benchmark.mjs" summarize --harness codex --model gpt-5.4 --notes compiler-a)"
printf '%s\n' "$compiler_summary_output" | grep -Fq $'clasp-compiler-maintenance\tcodex\tgpt-5.4'
printf '%s\n' "$compiler_summary_output" | grep -Fq '  series: compiler-a'
printf '%s\n' "$compiler_summary_output" | grep -Fq '  runs: 2'
printf '%s\n' "$compiler_summary_output" | grep -Fq '  passRate: 50%'
printf '%s\n' "$compiler_summary_output" | grep -Fq '  timeToGreenMs: 480'
printf '%s\n' "$compiler_summary_output" | grep -Fq '  medianDurationMs: 240'
printf '%s\n' "$compiler_summary_output" | grep -Fq '  medianTokens: 175'
printf '%s\n' "$compiler_summary_output" | grep -Fq '  medianUncachedTokens: 145'

interop_summary_output="$(node "$project_root/benchmarks/run-benchmark.mjs" summarize --harness codex --model gpt-5.4 --notes interop-a)"
printf '%s\n' "$interop_summary_output" | grep -Fq $'clasp-npm-interop\tcodex\tgpt-5.4'
printf '%s\n' "$interop_summary_output" | grep -Fq $'ts-npm-interop\tcodex\tgpt-5.4'
printf '%s\n' "$interop_summary_output" | grep -Fq $'clasp-python-interop\tcodex\tgpt-5.4'
printf '%s\n' "$interop_summary_output" | grep -Fq $'ts-python-interop\tcodex\tgpt-5.4'
printf '%s\n' "$interop_summary_output" | grep -Fq $'clasp-rust-interop\tcodex\tgpt-5.4'
printf '%s\n' "$interop_summary_output" | grep -Fq $'ts-rust-interop\tcodex\tgpt-5.4'
printf '%s\n' "$interop_summary_output" | grep -Fq 'npm-interop-comparison'
printf '%s\n' "$interop_summary_output" | grep -Fq 'python-interop-comparison'
printf '%s\n' "$interop_summary_output" | grep -Fq 'rust-interop-comparison'
printf '%s\n' "$interop_summary_output" | grep -Fq $'  codex\tgpt-5.4\tinterop-a'
printf '%s\n' "$interop_summary_output" | grep -Fq '    claspPassRate: 100%'
printf '%s\n' "$interop_summary_output" | grep -Fq '    tsPassRate: 50%'
printf '%s\n' "$interop_summary_output" | grep -Fq '    timeToGreenDeltaMs: -140'
printf '%s\n' "$interop_summary_output" | grep -Fq '    tokenDelta: -37'
printf '%s\n' "$interop_summary_output" | grep -Fq '    uncachedTokenDelta: -33'
printf '%s\n' "$interop_summary_output" | grep -Fq '    claspPassRate: 50%'
printf '%s\n' "$interop_summary_output" | grep -Fq '    tsPassRate: 50%'
printf '%s\n' "$interop_summary_output" | grep -Fq '    timeToGreenDeltaMs: -130'
printf '%s\n' "$interop_summary_output" | grep -Fq '    tokenDelta: -60'
printf '%s\n' "$interop_summary_output" | grep -Fq '    uncachedTokenDelta: -55'
printf '%s\n' "$interop_summary_output" | grep -Fq '    claspPassRate: 100%'
printf '%s\n' "$interop_summary_output" | grep -Fq '    tsPassRate: 100%'
printf '%s\n' "$interop_summary_output" | grep -Fq '    timeToGreenDeltaMs: -65'
printf '%s\n' "$interop_summary_output" | grep -Fq '    tokenDelta: -57'
printf '%s\n' "$interop_summary_output" | grep -Fq '    uncachedTokenDelta: -52'

interop_boundary_summary_output="$(node "$project_root/benchmarks/run-benchmark.mjs" summarize --harness codex --model gpt-5.4 --notes interop-boundary-a)"
printf '%s\n' "$interop_boundary_summary_output" | grep -Fq $'clasp-interop-boundary\tcodex\tgpt-5.4'
printf '%s\n' "$interop_boundary_summary_output" | grep -Fq $'ts-interop-boundary\tcodex\tgpt-5.4'
printf '%s\n' "$interop_boundary_summary_output" | grep -Fq 'interop-boundary-comparison'
printf '%s\n' "$interop_boundary_summary_output" | grep -Fq $'  codex\tgpt-5.4\tinterop-boundary-a'
printf '%s\n' "$interop_boundary_summary_output" | grep -Fq '    claspPassRate: 100%'
printf '%s\n' "$interop_boundary_summary_output" | grep -Fq '    tsPassRate: 50%'
printf '%s\n' "$interop_boundary_summary_output" | grep -Fq '    passRateDeltaPct: 50'
printf '%s\n' "$interop_boundary_summary_output" | grep -Fq '    timeToGreenDeltaMs: -185'
printf '%s\n' "$interop_boundary_summary_output" | grep -Fq '    tokenDelta: -50'
printf '%s\n' "$interop_boundary_summary_output" | grep -Fq '    uncachedTokenDelta: -47'

mixed_stack_summary_output="$(node "$project_root/benchmarks/run-benchmark.mjs" summarize --harness codex --model gpt-5.4 --notes mixed-stack-a)"
printf '%s\n' "$mixed_stack_summary_output" | grep -Fq 'mixed-stack-semantic-layer-comparison'
printf '%s\n' "$mixed_stack_summary_output" | grep -Fq $'  codex\tgpt-5.4\tmixed-stack-a'
printf '%s\n' "$mixed_stack_summary_output" | grep -Fq '    taskPairs: 4'
printf '%s\n' "$mixed_stack_summary_output" | grep -Fq '    claspCompletedTasks: 4/4'
printf '%s\n' "$mixed_stack_summary_output" | grep -Fq '    tsCompletedTasks: 4/4'
printf '%s\n' "$mixed_stack_summary_output" | grep -Fq '    claspRunPassRate: 88%'
printf '%s\n' "$mixed_stack_summary_output" | grep -Fq '    tsRunPassRate: 63%'
printf '%s\n' "$mixed_stack_summary_output" | grep -Fq '    passRateDeltaPct: 25'
printf '%s\n' "$mixed_stack_summary_output" | grep -Fq '    claspSuiteTimeToGreenMs: 440'
printf '%s\n' "$mixed_stack_summary_output" | grep -Fq '    tsSuiteTimeToGreenMs: 960'
printf '%s\n' "$mixed_stack_summary_output" | grep -Fq '    timeToGreenDeltaMs: -520'
printf '%s\n' "$mixed_stack_summary_output" | grep -Fq '    claspSuiteMedianTokens: 469'
printf '%s\n' "$mixed_stack_summary_output" | grep -Fq '    tsSuiteMedianTokens: 673'
printf '%s\n' "$mixed_stack_summary_output" | grep -Fq '    claspFeatureThroughputPerHour: 32727.27'
printf '%s\n' "$mixed_stack_summary_output" | grep -Fq '    tsFeatureThroughputPerHour: 15000'
printf '%s\n' "$mixed_stack_summary_output" | grep -Fq '    throughputDeltaPct: 118'
printf '%s\n' "$mixed_stack_summary_output" | grep -Fq '    tokenDelta: -204'
printf '%s\n' "$mixed_stack_summary_output" | grep -Fq '    uncachedTokenDelta: -187'

secret_handling_summary_output="$(node "$project_root/benchmarks/run-benchmark.mjs" summarize --harness codex --model gpt-5.4 --notes secret-handling-a)"
printf '%s\n' "$secret_handling_summary_output" | grep -Fq $'clasp-secret-handling\tcodex\tgpt-5.4'
printf '%s\n' "$secret_handling_summary_output" | grep -Fq $'ts-secret-handling\tcodex\tgpt-5.4'
printf '%s\n' "$secret_handling_summary_output" | grep -Fq 'secret-handling-comparison'
printf '%s\n' "$secret_handling_summary_output" | grep -Fq $'  codex\tgpt-5.4\tsecret-handling-a'
printf '%s\n' "$secret_handling_summary_output" | grep -Fq '    claspPassRate: 100%'
printf '%s\n' "$secret_handling_summary_output" | grep -Fq '    tsPassRate: 50%'
printf '%s\n' "$secret_handling_summary_output" | grep -Fq '    passRateDeltaPct: 50'
printf '%s\n' "$secret_handling_summary_output" | grep -Fq '    timeToGreenDeltaMs: -230'
printf '%s\n' "$secret_handling_summary_output" | grep -Fq '    tokenDelta: -58'
printf '%s\n' "$secret_handling_summary_output" | grep -Fq '    uncachedTokenDelta: -53'

audit_log_summary_output="$(node "$project_root/benchmarks/run-benchmark.mjs" summarize --harness codex --model gpt-5.4 --notes audit-log-a)"
printf '%s\n' "$audit_log_summary_output" | grep -Fq $'clasp-audit-log\tcodex\tgpt-5.4'
printf '%s\n' "$audit_log_summary_output" | grep -Fq $'ts-audit-log\tcodex\tgpt-5.4'
printf '%s\n' "$audit_log_summary_output" | grep -Fq 'audit-log-comparison'
printf '%s\n' "$audit_log_summary_output" | grep -Fq $'  codex\tgpt-5.4\taudit-log-a'
printf '%s\n' "$audit_log_summary_output" | grep -Fq '    claspPassRate: 100%'
printf '%s\n' "$audit_log_summary_output" | grep -Fq '    tsPassRate: 50%'
printf '%s\n' "$audit_log_summary_output" | grep -Fq '    passRateDeltaPct: 50'
printf '%s\n' "$audit_log_summary_output" | grep -Fq '    timeToGreenDeltaMs: -300'
printf '%s\n' "$audit_log_summary_output" | grep -Fq '    tokenDelta: -65'
printf '%s\n' "$audit_log_summary_output" | grep -Fq '    uncachedTokenDelta: -60'

public_app_summary_output="$(node "$project_root/benchmarks/run-benchmark.mjs" summarize --harness codex --model gpt-5.4 --notes public-app)"
printf '%s\n' "$public_app_summary_output" | grep -Fq 'main-public-app-comparison'
printf '%s\n' "$public_app_summary_output" | grep -Fq $'  codex\tgpt-5.4\tpublic-app'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    taskPairs: 4'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    claspCompletedTasks: 4/4'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    tsCompletedTasks: 4/4'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    claspRunPassRate: 100%'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    tsRunPassRate: 100%'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    passRateDeltaPct: 0'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    claspSuiteTimeToGreenMs: 630000'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    tsSuiteTimeToGreenMs: 870000'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    timeToGreenDeltaMs: -240000'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    claspSuiteMedianTokens: 550'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    tsSuiteMedianTokens: 665'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    claspFeatureThroughputPerHour: 22.86'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    tsFeatureThroughputPerHour: 16.55'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    throughputDeltaPct: 38'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    tokenDelta: -115'
printf '%s\n' "$public_app_summary_output" | grep -Fq '    uncachedTokenDelta: -100'

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

PATH="$tmp_bin:$PATH" CLASP_ALLOW_BOOTSTRAP_RECOVERY=true CLASP_BENCHMARK_WORKFLOW_ASSISTANCE=compiler-assisted bash "$project_root/benchmarks/run-codex-series.sh" lead-segment 2 remediation-a gpt-5.4
command_log="$(cat "$tmp_bin/nix.log")"
bundle_manifest="$project_root/benchmarks/bundles/remediation-a--codex--gpt-5.4--raw-repo--workflow-assistance-compiler-assisted.json"
synthetic_files+=("$bundle_manifest")
printf '%s\n' "$command_log" | grep -Fq 'run clasp-lead-segment'
printf '%s\n' "$command_log" | grep -Fq 'run ts-lead-segment'
printf '%s\n' "$command_log" | grep -Fq -- '--notes remediation-a-1'
printf '%s\n' "$command_log" | grep -Fq -- '--notes remediation-a-2'
printf '%s\n' "$command_log" | grep -Fq -- '--mode raw-repo'
printf '%s\n' "$command_log" | grep -Fq -- '--bundle-manifest'
node -e '
const fs = require("node:fs");
const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (manifest.bundleType !== "clasp-benchmark-fairness-bundle") {
  throw new Error("unexpected frozen bundle type");
}
if (manifest.mode !== "raw-repo" || manifest.sampleCount !== 2) {
  throw new Error("frozen bundle did not record the expected protocol");
}
if (!Array.isArray(manifest.samples) || manifest.samples.length !== 2) {
  throw new Error("frozen bundle is missing repeated sample orders");
}
if (!Array.isArray(manifest.files) || manifest.files.length === 0) {
  throw new Error("frozen bundle is missing file digests");
}
const firstOrder = manifest.samples[0].runOrder.map((entry) => entry.taskId).join(",");
const secondOrder = manifest.samples[1].runOrder.map((entry) => entry.taskId).join(",");
if (firstOrder !== "clasp-lead-segment,ts-lead-segment" && firstOrder !== "ts-lead-segment,clasp-lead-segment") {
  throw new Error(`unexpected first randomized order: ${firstOrder}`);
}
if (manifest.samples[0].seed === manifest.samples[1].seed) {
  throw new Error("expected repeated samples to use distinct deterministic shuffle seeds");
}
' "$bundle_manifest"

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" CLASP_ALLOW_BOOTSTRAP_RECOVERY=true CLASP_BENCHMARK_WORKFLOW_ASSISTANCE=browser-only bash "$project_root/benchmarks/run-codex-series.sh" control-plane 2 containment-a gpt-5.4
control_command_log="$(cat "$tmp_bin/nix.log")"
synthetic_files+=("$project_root/benchmarks/bundles/containment-a--codex--gpt-5.4--raw-repo--workflow-assistance-browser-only.json")
printf '%s\n' "$control_command_log" | grep -Fq 'run clasp-control-plane'
printf '%s\n' "$control_command_log" | grep -Fq 'run ts-control-plane'
printf '%s\n' "$control_command_log" | grep -Fq -- '--notes containment-a-1'
printf '%s\n' "$control_command_log" | grep -Fq -- '--notes containment-a-2'
test -f "$project_root/benchmarks/bundles/containment-a--codex--gpt-5.4--raw-repo--workflow-assistance-browser-only.json"

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" CLASP_ALLOW_BOOTSTRAP_RECOVERY=true bash "$project_root/benchmarks/run-codex-series.sh" external-adaptation 2 objective-a gpt-5.4
objective_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$objective_command_log" | grep -Fq 'run clasp-external-adaptation'
printf '%s\n' "$objective_command_log" | grep -Fq 'run ts-external-adaptation'
printf '%s\n' "$objective_command_log" | grep -Fq -- '--notes objective-a-1'
printf '%s\n' "$objective_command_log" | grep -Fq -- '--notes objective-a-2'

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" CLASP_ALLOW_BOOTSTRAP_RECOVERY=true bash "$project_root/benchmarks/run-codex-series.sh" interop-boundary 2 interop-boundary-a gpt-5.4
interop_boundary_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$interop_boundary_command_log" | grep -Fq 'run clasp-interop-boundary'
printf '%s\n' "$interop_boundary_command_log" | grep -Fq 'run ts-interop-boundary'
printf '%s\n' "$interop_boundary_command_log" | grep -Fq -- '--notes interop-boundary-a-1'
printf '%s\n' "$interop_boundary_command_log" | grep -Fq -- '--notes interop-boundary-a-2'

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" CLASP_ALLOW_BOOTSTRAP_RECOVERY=true bash "$project_root/benchmarks/run-codex-series.sh" mixed-stack-semantic-layer 2 mixed-stack-a gpt-5.4
mixed_stack_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$mixed_stack_command_log" | grep -Fq 'run clasp-npm-interop'
printf '%s\n' "$mixed_stack_command_log" | grep -Fq 'run ts-python-interop'
printf '%s\n' "$mixed_stack_command_log" | grep -Fq 'run clasp-rust-interop'
printf '%s\n' "$mixed_stack_command_log" | grep -Fq 'run ts-interop-boundary'
printf '%s\n' "$mixed_stack_command_log" | grep -Fq -- '--notes mixed-stack-a-1'
printf '%s\n' "$mixed_stack_command_log" | grep -Fq -- '--notes mixed-stack-a-2'

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" CLASP_ALLOW_BOOTSTRAP_RECOVERY=true bash "$project_root/benchmarks/run-codex-series.sh" secret-handling 2 secret-handling-a gpt-5.4
secret_handling_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$secret_handling_command_log" | grep -Fq 'run clasp-secret-handling'
printf '%s\n' "$secret_handling_command_log" | grep -Fq 'run ts-secret-handling'

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" CLASP_ALLOW_BOOTSTRAP_RECOVERY=true bash "$project_root/benchmarks/run-codex-series.sh" audit-log 2 audit-log-a gpt-5.4
audit_log_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$audit_log_command_log" | grep -Fq 'run clasp-audit-log'
printf '%s\n' "$audit_log_command_log" | grep -Fq 'run ts-audit-log'
printf '%s\n' "$secret_handling_command_log" | grep -Fq -- '--notes secret-handling-a-1'
printf '%s\n' "$secret_handling_command_log" | grep -Fq -- '--notes secret-handling-a-2'

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" CLASP_ALLOW_BOOTSTRAP_RECOVERY=true bash "$project_root/benchmarks/run-codex-series.sh" lead-priority 2 priority-a gpt-5.4
priority_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$priority_command_log" | grep -Fq 'run clasp-lead-priority'
printf '%s\n' "$priority_command_log" | grep -Fq 'run ts-lead-priority'
printf '%s\n' "$priority_command_log" | grep -Fq -- '--notes priority-a-1'
printf '%s\n' "$priority_command_log" | grep -Fq -- '--notes priority-a-2'

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" CLASP_ALLOW_BOOTSTRAP_RECOVERY=true bash "$project_root/benchmarks/run-codex-series.sh" lead-rejection 2 rejection-a gpt-5.4
rejection_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$rejection_command_log" | grep -Fq 'run clasp-lead-rejection'
printf '%s\n' "$rejection_command_log" | grep -Fq 'run ts-lead-rejection'
printf '%s\n' "$rejection_command_log" | grep -Fq -- '--notes rejection-a-1'
printf '%s\n' "$rejection_command_log" | grep -Fq -- '--notes rejection-a-2'

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" CLASP_ALLOW_BOOTSTRAP_RECOVERY=true bash "$project_root/benchmarks/run-codex-series.sh" syntax-form 2 syntax-a gpt-5.4
syntax_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$syntax_command_log" | grep -Fq 'run clasp-syntax-compact'
printf '%s\n' "$syntax_command_log" | grep -Fq 'run clasp-syntax-verbose'
printf '%s\n' "$syntax_command_log" | grep -Fq -- '--notes syntax-a-1'
printf '%s\n' "$syntax_command_log" | grep -Fq -- '--notes syntax-a-2'

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" CLASP_ALLOW_BOOTSTRAP_RECOVERY=true bash "$project_root/benchmarks/run-codex-series.sh" app 2 public-app gpt-5.4
app_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$app_command_log" | grep -Fq 'run clasp-lead-priority'
printf '%s\n' "$app_command_log" | grep -Fq 'run ts-lead-priority'
printf '%s\n' "$app_command_log" | grep -Fq 'run clasp-lead-rejection'
printf '%s\n' "$app_command_log" | grep -Fq 'run ts-lead-rejection'
printf '%s\n' "$app_command_log" | grep -Fq 'run clasp-lead-segment'
printf '%s\n' "$app_command_log" | grep -Fq 'run ts-lead-segment'
printf '%s\n' "$app_command_log" | grep -Fq 'run clasp-external-adaptation'
printf '%s\n' "$app_command_log" | grep -Fq 'run ts-external-adaptation'
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
PATH="$tmp_bin:$PATH" CLASP_ALLOW_BOOTSTRAP_RECOVERY=true CLASP_BENCHMARK_WORKFLOW_ASSISTANCE=raw-text bash "$project_root/benchmarks/run-claude-series.sh" lead-priority 2 claude-a sonnet
claude_command_log="$(cat "$tmp_bin/nix.log")"
synthetic_files+=("$project_root/benchmarks/bundles/claude-a--claude-code--sonnet--raw-repo--workflow-assistance-raw-text.json")
printf '%s\n' "$claude_command_log" | grep -Fq 'run clasp-lead-priority'
printf '%s\n' "$claude_command_log" | grep -Fq 'run ts-lead-priority'
printf '%s\n' "$claude_command_log" | grep -Fq -- '--harness claude-code'
printf '%s\n' "$claude_command_log" | grep -Fq -- '--model sonnet'
printf '%s\n' "$claude_command_log" | grep -Fq -- '--notes claude-a-1'
printf '%s\n' "$claude_command_log" | grep -Fq -- '--notes claude-a-2'
test -f "$project_root/benchmarks/bundles/claude-a--claude-code--sonnet--raw-repo--workflow-assistance-raw-text.json"

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" CLASP_ALLOW_BOOTSTRAP_RECOVERY=true bash "$project_root/benchmarks/run-claude-series.sh" syntax-form 2 syntax-a sonnet
claude_syntax_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$claude_syntax_command_log" | grep -Fq 'run clasp-syntax-compact'
printf '%s\n' "$claude_syntax_command_log" | grep -Fq 'run clasp-syntax-verbose'
printf '%s\n' "$claude_syntax_command_log" | grep -Fq -- '--harness claude-code'
printf '%s\n' "$claude_syntax_command_log" | grep -Fq -- '--model sonnet'
printf '%s\n' "$claude_syntax_command_log" | grep -Fq -- '--notes syntax-a-1'
printf '%s\n' "$claude_syntax_command_log" | grep -Fq -- '--notes syntax-a-2'

: >"$tmp_bin/nix.log"
PATH="$tmp_bin:$PATH" CLASP_ALLOW_BOOTSTRAP_RECOVERY=true bash "$project_root/benchmarks/run-claude-series.sh" app 2 public-app sonnet
claude_app_command_log="$(cat "$tmp_bin/nix.log")"
printf '%s\n' "$claude_app_command_log" | grep -Fq 'run clasp-lead-priority'
printf '%s\n' "$claude_app_command_log" | grep -Fq 'run ts-lead-priority'
printf '%s\n' "$claude_app_command_log" | grep -Fq 'run clasp-lead-rejection'
printf '%s\n' "$claude_app_command_log" | grep -Fq 'run ts-lead-rejection'
printf '%s\n' "$claude_app_command_log" | grep -Fq 'run clasp-lead-segment'
printf '%s\n' "$claude_app_command_log" | grep -Fq 'run ts-lead-segment'
printf '%s\n' "$claude_app_command_log" | grep -Fq 'run clasp-external-adaptation'
printf '%s\n' "$claude_app_command_log" | grep -Fq 'run ts-external-adaptation'
printf '%s\n' "$claude_app_command_log" | grep -Fq -- '--harness claude-code'
printf '%s\n' "$claude_app_command_log" | grep -Fq -- '--model sonnet'
printf '%s\n' "$claude_app_command_log" | grep -Fq -- '--notes public-app-1'
printf '%s\n' "$claude_app_command_log" | grep -Fq -- '--notes public-app-2'

claude_workspace="$project_root/benchmarks/workspaces/claude-usage-check"
rm -rf "$claude_workspace"
node "$project_root/benchmarks/run-benchmark.mjs" prepare clasp-lead-segment --workspace "$claude_workspace" --allow-bootstrap-recovery true >/dev/null
cp "$project_root/examples/lead-app/Shared/Lead.clasp" "$claude_workspace/Shared/Lead.clasp"

claude_bundle="$project_root/benchmarks/bundles/claude-usage-check.json"
synthetic_files+=("$claude_bundle")
node "$project_root/benchmarks/run-benchmark.mjs" freeze lead-segment \
  --count 2 \
  --harness claude-code \
  --model sonnet \
  --mode file-hinted \
  --notes claude-usage-check \
  --output "$claude_bundle" \
  --allow-bootstrap-recovery true >/dev/null

cat >"$claude_workspace/claude-run.jsonl" <<EOF
{"type":"assistant","message":{"usage":{"input_tokens":40,"cache_creation_input_tokens":5,"cache_read_input_tokens":10,"output_tokens":12}}}
{"type":"assistant","message":{"usage":{"input_tokens":30,"cache_creation_input_tokens":0,"cache_read_input_tokens":20,"output_tokens":8}}}
{"type":"result","subtype":"success","duration_ms":250}
EOF

cat >"$claude_workspace/benchmark-phases.json" <<EOF
{
  "discoveryMs": 21,
  "firstEditMs": 144,
  "firstVerifyMs": 211,
  "timeToGreenMs": 250
}
EOF

node "$project_root/benchmarks/run-benchmark.mjs" verify clasp-lead-segment \
  --workspace "$claude_workspace" \
  --harness claude-code \
  --model sonnet \
  --mode file-hinted \
  --bundle-manifest "$claude_bundle" \
  --sample-count 2 \
  --sample-index 1 \
  --notes claude-usage-check \
  --allow-bootstrap-recovery true >/dev/null

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
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"mode": "file-hinted"'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"prompt": 105'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"completion": 20'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"total": 125'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"cachedInputTokens": 30'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"uncachedInputTokens": 75'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"uncachedTotal": 95'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"sampleIndex": 1'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"manifestFile": "benchmarks/bundles/claude-usage-check.json"'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"discoveryMs": 21'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"firstEditMs": 144'
printf '%s\n' "$(cat "$latest_result")" | grep -Fq '"firstVerifyMs": 211'

package_a="$tmp_bin/remediation-a.tar.gz"
package_b="$tmp_bin/remediation-b.tar.gz"
node "$project_root/benchmarks/run-benchmark.mjs" package \
  --harness codex \
  --model gpt-5.4 \
  --notes remediation-a \
  --output "$package_a" >/dev/null
node "$project_root/benchmarks/run-benchmark.mjs" package \
  --harness codex \
  --model gpt-5.4 \
  --notes remediation-a \
  --output "$package_b" >/dev/null

cmp -s "$package_a" "$package_b"
package_sha_a="$(sha256sum "$package_a" | awk '{print $1}')"
package_sha_b="$(sha256sum "$package_b" | awk '{print $1}')"
[[ "$package_sha_a" == "$package_sha_b" ]]

package_listing="$(tar -tzf "$package_a")"
printf '%s\n' "$package_listing" | grep -Fq './AGENTS.md'
printf '%s\n' "$package_listing" | grep -Fq './benchmarks/package-manifest.json'
printf '%s\n' "$package_listing" | grep -Fq './benchmarks/results/2026-03-01T10-01-00.000Z--clasp-lead-segment--codex.json'
printf '%s\n' "$package_listing" | grep -Fq './benchmarks/results/2026-03-01T10-04-00.000Z--ts-lead-segment--codex.json'
printf '%s\n' "$package_listing" | grep -Fq './benchmarks/tasks/clasp-lead-segment/task.json'
printf '%s\n' "$package_listing" | grep -Fq './benchmarks/tasks/ts-lead-segment/task.json'

manifest_path="$tmp_bin/package-manifest.json"
tar -xOzf "$package_a" ./benchmarks/package-manifest.json >"$manifest_path"
node -e '
const fs = require("node:fs");
const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (manifest.resultCount !== 4) {
  throw new Error(`expected 4 packaged results, received ${manifest.resultCount}`);
}
if (manifest.filters.harness !== "codex" || manifest.filters.model !== "gpt-5.4" || manifest.filters.notes !== "remediation-a") {
  throw new Error("package filters were not preserved");
}
const taskIds = manifest.taskIds.join(",");
if (taskIds !== "clasp-lead-segment,ts-lead-segment") {
  throw new Error(`unexpected task ids: ${taskIds}`);
}
if (!Array.isArray(manifest.files) || manifest.files.length === 0) {
  throw new Error("package manifest is missing file digests");
}
if (!manifest.reproducibility || manifest.reproducibility.archiveFormat !== "tar.gz") {
  throw new Error("package manifest is missing reproducibility metadata");
}
if (!manifest.publicationProtocol || manifest.publicationProtocol.repeatedSamples !== 2) {
  throw new Error("package manifest is missing repeated-sample protocol metadata");
}
if (!Array.isArray(manifest.publicationProtocol.modes) || manifest.publicationProtocol.modes.join(",") !== "raw-repo") {
  throw new Error("package manifest is missing benchmark mode metadata");
}
if (manifest.publicationProtocol.phaseDecomposition !== true) {
  throw new Error("package manifest did not record phase-decomposed reporting");
}
' "$manifest_path"
