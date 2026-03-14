#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo "usage: $0 <task-file> <workspace> <report-json> <log-jsonl> [feedback-file]" >&2
  exit 1
fi

task_file="$1"
workspace="$2"
report_json="$3"
log_jsonl="$4"
feedback_file="${5:-}"
model="${CODEX_MODEL:-gpt-5.4}"
reasoning_effort="${CODEX_REASONING_EFFORT:-medium}"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
base_schema_file="$project_root/agents/schemas/builder-report.schema.json"
schema_file="$(mktemp "${TMPDIR:-/tmp}/clasp-builder-schema.XXXXXX")"
mv "$schema_file" "${schema_file}.json"
schema_file="${schema_file}.json"
prompt_file="$(mktemp "${TMPDIR:-/tmp}/clasp-builder-prompt.XXXXXX")"
shared_codex_home="${CODEX_HOME:-$HOME/.codex}"
run_dir="$(dirname "$report_json")"
isolated_codex_home="$run_dir/codex-home"

source "$project_root/scripts/clasp-codex-home.sh"
source "$project_root/scripts/clasp-swarm-common.sh"

cleanup() {
  rm -f "$prompt_file"
  rm -f "$schema_file"
}

trap cleanup EXIT

clasp_prepare_isolated_codex_home "$shared_codex_home" "$isolated_codex_home"

feedback_required=0
feedback_activation_task="$(clasp_swarm_feedback_activation_task)"
if clasp_swarm_feedback_required "$project_root" "$feedback_activation_task"; then
  feedback_required=1
fi

node - <<'EOF' "$base_schema_file" "$schema_file" "$feedback_required"
const fs = require("fs");
const [basePath, outPath, feedbackFlag] = process.argv.slice(2);
const schema = JSON.parse(fs.readFileSync(basePath, "utf8"));
const requireFeedback = feedbackFlag === "1";

if (!schema.properties || !schema.properties.feedback) {
  throw new Error("builder schema is missing feedback property");
}

if (requireFeedback) {
  if (!schema.required.includes("feedback")) {
    schema.required.push("feedback");
  }
} else {
  delete schema.properties.feedback;
  schema.required = schema.required.filter((item) => item !== "feedback");
}

fs.writeFileSync(outPath, `${JSON.stringify(schema, null, 2)}\n`, "utf8");
EOF

{
  cat <<'EOF'
You are the builder subagent for the Clasp language repository.

Your job:
- implement exactly the task described below in the current checkout
- keep changes as small and local as possible
- add or update tests
- run the full repo verification command before finishing

Rules:
- Work only in the current checkout.
- The current checkout may be a plain copied workspace rather than a Git repository.
- Read `AGENTS.md` first if it exists.
- Do not rely on Git commands; use direct file inspection and `diff` if needed.
- Do not push.
- Prefer minimal, coherent edits over broad refactors.
- Start with the file paths named in the task findings or follow-up before scanning anything else.
- Avoid broad repo tours and repeated rereads of unrelated modules.
- Update docs only if the task changes the visible language/runtime behavior.
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path in addition to any local regression.
- Before finishing, run `bash scripts/verify-all.sh`.

Your final response must satisfy the provided JSON schema.
EOF
  if (( feedback_required )); then
    cat <<EOF
- Because ${feedback_activation_task} is complete, this task must leave a feedback artifact for future agents.
- In your final JSON include a \`feedback\` object with:
  - \`summary\`: short practical take for future agents
  - \`ergonomics\`: what felt good or bad in the language/tooling for this task
  - \`follow_ups\`: concrete follow-on improvements or missing capabilities
  - \`warnings\`: traps or misleading surfaces future agents should watch for
- Keep this feedback concrete and task-specific; do not write generic encouragement.
EOF
    while IFS= read -r dep; do
      [[ -z "$dep" ]] && continue
      dep_feedback="$(clasp_swarm_feedback_path "$project_root" "$dep")"
      if [[ -f "$dep_feedback" ]]; then
        node - <<'EOF' "$dep_feedback"
const fs = require("fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const asList = (value) => Array.isArray(value) ? value.slice(0, 3) : [];
console.log("");
console.log(`Relevant prior feedback from ${report.task_id}:`);
if (typeof report.summary === "string" && report.summary.length > 0) {
  console.log(`Summary: ${report.summary}`);
}
for (const item of asList(report.ergonomics)) {
  console.log(`- ergonomics: ${item}`);
}
for (const item of asList(report.follow_ups)) {
  console.log(`- follow_up: ${item}`);
}
for (const item of asList(report.warnings)) {
  console.log(`- warning: ${item}`);
}
EOF
      fi
    done < <(clasp_swarm_task_dependencies "$task_file")
  fi
  if [[ -n "$feedback_file" && -f "$feedback_file" ]]; then
    node - <<'EOF' "$feedback_file"
const fs = require("fs");
const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const truncate = (value, max) =>
  value.length > max ? `${value.slice(0, max - 3)}...` : value;
const findings = (Array.isArray(report.findings) ? report.findings : [])
  .slice(0, 5)
  .map((item) => truncate(String(item), 240));
const followUp = (Array.isArray(report.follow_up) ? report.follow_up : [])
  .slice(0, 5)
  .map((item) => truncate(String(item), 200));
console.log("");
console.log("Verifier feedback from the previous attempt:");
if (typeof report.summary === "string" && report.summary.length > 0) {
  console.log(`Summary: ${truncate(report.summary, 320)}`);
}
if (findings.length > 0) {
  console.log("Findings:");
  for (const item of findings) {
    console.log(`- ${item}`);
  }
}
if (followUp.length > 0) {
  console.log("Follow up:");
  for (const item of followUp) {
    console.log(`- ${item}`);
  }
}
EOF
  fi
  cat <<'EOF'

Task:
EOF
  cat "$task_file"
} > "$prompt_file"

clasp_swarm_assert_prompt_size "$prompt_file" "builder"

CODEX_HOME="$isolated_codex_home" codex exec - \
  --json \
  -m "$model" \
  -c "model_reasoning_effort=\"$reasoning_effort\"" \
  --skip-git-repo-check \
  --cd "$workspace" \
  --dangerously-bypass-approvals-and-sandbox \
  --ephemeral \
  --output-schema "$schema_file" \
  -o "$report_json" \
  < "$prompt_file" \
  > "$log_jsonl"
