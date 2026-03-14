#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 5 ]]; then
  echo "usage: $0 <task-id|app|control-plane|lead-priority|lead-rejection|lead-segment|external-adaptation|foreign-interop|mixed-stack-semantic-layer|interop-boundary|secret-handling|authorization-data-access|audit-log|npm-interop|python-interop|rust-interop|compiler-maintenance|syntax-form> <count> <note-prefix> [model] [mode]" >&2
  exit 1
fi

task_id="$1"
count="$2"
note_prefix="$3"
model="${4:-sonnet}"
mode="${5:-${CLASP_BENCHMARK_MODE:-raw-repo}}"
workflow_assistance="${CLASP_BENCHMARK_WORKFLOW_ASSISTANCE:-unspecified}"
workflow_assistance_slug="$(printf '%s' "$workflow_assistance" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
if [[ -z "$workflow_assistance_slug" ]]; then
  workflow_assistance_slug="unspecified"
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
bundle_manifest="$project_root/benchmarks/bundles/${note_prefix}--claude-code--${model//\//-}--${mode}--workflow-assistance-${workflow_assistance_slug}.json"
recovery_args=()

if [[ "${CLASP_ALLOW_BOOTSTRAP_RECOVERY:-}" == "true" ]]; then
  recovery_args=(--allow-bootstrap-recovery true)
fi

node "$project_root/benchmarks/run-benchmark.mjs" freeze "$task_id" \
  --count "$count" \
  --harness claude-code \
  --model "$model" \
  --mode "$mode" \
  --notes "$note_prefix" \
  --output "$bundle_manifest" \
  "${recovery_args[@]}" >/dev/null

for index in $(seq 1 "$count"); do
  note="${note_prefix}-${index}"
  mapfile -t task_ids < <(
    node -e '
const fs = require("node:fs");
const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const sampleIndex = Number.parseInt(process.argv[2], 10);
const sample = manifest.samples.find((entry) => entry.sampleIndex === sampleIndex);
if (!sample) {
  process.exit(1);
}
for (const entry of sample.runOrder) {
  console.log(entry.taskId);
}
' "$bundle_manifest" "$index"
  )

  for current_task_id in "${task_ids[@]}"; do
    workspace="$project_root/benchmarks/workspaces/${current_task_id}-${note}"
    agent_command="CLAUDE_MODEL=$model bash \"$project_root/benchmarks/run-claude-harness.sh\" \"\$CLASP_BENCHMARK_PROMPT_FILE\" \"\$CLASP_BENCHMARK_WORKSPACE\""

    nix develop "$project_root" --command node "$project_root/benchmarks/run-benchmark.mjs" run \
      "$current_task_id" \
      --workspace "$workspace" \
      --harness claude-code \
      --model "$model" \
      --mode "$mode" \
      --notes "$note" \
      --bundle-manifest "$bundle_manifest" \
      --sample-count "$count" \
      --sample-index "$index" \
      --agent-command "$agent_command" \
      "${recovery_args[@]}"
  done
done
