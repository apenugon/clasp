#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <task-file> <workspace> [runtime-dir]" >&2
  exit 1
fi

task_file="$1"
workspace_input="$2"
runtime_dir_input="${3:-}"
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace="$(cd "$workspace_input" && pwd)"
task_id="$(basename "$task_file" .md)"
runtime_dir="${runtime_dir_input:-$workspace/.clasp-codex-loop/$task_id}"
runtime_dir="$(mkdir -p "$runtime_dir" && cd "$runtime_dir" && pwd)"
baseline_workspace="$runtime_dir/baseline-workspace"
verifier_workspace="$runtime_dir/verifier-workspace"
runs_root="$runtime_dir/runs"
lock_file="$runtime_dir/loop.lock"
max_attempts="${CLASP_CODEX_LOOP_MAX_ATTEMPTS:-5}"
reset_baseline="${CLASP_CODEX_LOOP_RESET_BASELINE:-0}"
builder_timeout_seconds="${CLASP_CODEX_LOOP_BUILDER_TIMEOUT_SECONDS:-0}"
verifier_timeout_seconds="${CLASP_CODEX_LOOP_VERIFIER_TIMEOUT_SECONDS:-0}"

mkdir -p "$runs_root"

copy_workspace() {
  local src="$1"
  local dst="$2"

  mkdir -p "$dst"
  find "$dst" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
  (
    cd "$src"
    tar \
      --exclude=.git \
      --exclude=.clasp-agents \
      --exclude=.clasp-agent-worktrees \
      --exclude=.clasp-agent-workspaces \
      --exclude=.clasp-codex-loop \
      --exclude=dist \
      --exclude=dist-newstyle \
      --exclude=result \
      --exclude=benchmarks/results \
      --exclude=benchmarks/workspaces \
      -cf - .
  ) | (
    cd "$dst"
    tar -xf -
  )
}

run_with_timeout() {
  local timeout_seconds="$1"
  shift

  if [[ -z "$timeout_seconds" || "$timeout_seconds" == "0" ]]; then
    "$@"
    return 0
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=30s "${timeout_seconds}s" "$@"
  else
    "$@"
  fi
}

write_builder_failure_report() {
  local report_path="$1"
  local stage="$2"
  local exit_code="$3"

  node - <<'EOF' "$report_path" "$stage" "$exit_code"
const fs = require("fs");
const [reportPath, stage, exitCode] = process.argv.slice(2);
const code = Number(exitCode);
const statusText = Number.isNaN(code) ? String(exitCode) : String(code);
const report = {
  summary: `Loop builder step failed during ${stage}.`,
  files_touched: [],
  tests_run: [],
  residual_risks: [
    `${stage} exited with status ${statusText}`,
    "builder did not return a structured report for this attempt",
  ],
};
fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
EOF
}

write_verifier_failure_report() {
  local report_path="$1"
  local stage="$2"
  local exit_code="$3"

  node - <<'EOF' "$report_path" "$stage" "$exit_code"
const fs = require("fs");
const [reportPath, stage, exitCode] = process.argv.slice(2);
const code = Number(exitCode);
const statusText = Number.isNaN(code) ? String(exitCode) : String(code);
const report = {
  verdict: "fail",
  summary: `Fail: loop ${stage} failed before verifier could complete cleanly.`,
  findings: [
    `${stage} exited with status ${statusText}`,
    "The loop recovered by recording this attempt as a failed verification instead of exiting.",
  ],
  tests_run: [],
  follow_up: [
    "Inspect the builder/verifier logs for the failed attempt.",
    "Fix the underlying runtime or tool failure and let the next loop attempt continue.",
  ],
};
fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
EOF
}

verdict_of() {
  node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(String(data.verdict || ""));' "$1"
}

summary_of() {
  node -e 'const fs=require("fs"); const data=JSON.parse(fs.readFileSync(process.argv[1],"utf8")); process.stdout.write(String(data.summary || ""));' "$1"
}

if [[ "$reset_baseline" == "1" || ! -f "$baseline_workspace/.snapshot-ready" ]]; then
  rm -rf "$baseline_workspace"
  mkdir -p "$baseline_workspace"
  copy_workspace "$workspace" "$baseline_workspace"
  date -u +%Y-%m-%dT%H:%M:%SZ > "$baseline_workspace/.snapshot-ready"
fi

exec 9>"$lock_file"
if ! flock -n 9; then
  echo "codex loop is already running for $task_id" >&2
  exit 1
fi

feedback_file=""
attempt=1

while :; do
  if [[ "$max_attempts" != "0" && "$attempt" -gt "$max_attempts" ]]; then
    echo "loop exhausted after $((attempt - 1)) attempts for $task_id" >&2
    exit 1
  fi

  run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  run_dir="$runs_root/$run_stamp-attempt$attempt"
  mkdir -p "$run_dir"

  builder_report="$run_dir/builder-report.json"
  builder_log="$run_dir/builder-log.jsonl"
  verifier_report="$run_dir/verifier-report.json"
  verifier_log="$run_dir/verifier-log.jsonl"

  echo "builder attempt=$attempt task=$task_id"
  builder_status=0
  if [[ -n "$feedback_file" ]]; then
    run_with_timeout "$builder_timeout_seconds" \
      bash "$project_root/scripts/clasp-builder.sh" \
      "$task_file" \
      "$workspace" \
      "$builder_report" \
      "$builder_log" \
      "$feedback_file" || builder_status=$?
  else
    run_with_timeout "$builder_timeout_seconds" \
      bash "$project_root/scripts/clasp-builder.sh" \
      "$task_file" \
      "$workspace" \
      "$builder_report" \
      "$builder_log" || builder_status=$?
  fi

  if [[ "$builder_status" -ne 0 ]]; then
    echo "builder failed status=$builder_status task=$task_id attempt=$attempt"
  fi
  if [[ ! -f "$builder_report" ]]; then
    write_builder_failure_report "$builder_report" "builder" "$builder_status"
  fi

  copy_workspace "$workspace" "$verifier_workspace"

  echo "verifier attempt=$attempt task=$task_id"
  verifier_status=0
  run_with_timeout "$verifier_timeout_seconds" \
    bash "$project_root/scripts/clasp-verifier.sh" \
    "$task_file" \
    "$verifier_workspace" \
    "$baseline_workspace" \
    "$verifier_report" \
    "$verifier_log" || verifier_status=$?

  if [[ "$verifier_status" -ne 0 ]]; then
    echo "verifier failed status=$verifier_status task=$task_id attempt=$attempt"
  fi
  if [[ ! -f "$verifier_report" || "$verifier_status" -ne 0 ]]; then
    write_verifier_failure_report "$verifier_report" "verifier" "$verifier_status"
  fi

  verdict="$(verdict_of "$verifier_report")"
  summary="$(summary_of "$verifier_report")"

  echo "verifier verdict=$verdict summary=${summary:-"(none)"}"

  if [[ "$verdict" == "pass" ]]; then
    echo "loop passed after $attempt attempt(s)"
    exit 0
  fi

  feedback_file="$verifier_report"
  attempt=$((attempt + 1))
done
