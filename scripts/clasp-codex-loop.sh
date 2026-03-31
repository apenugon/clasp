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
feedback_path="$runtime_dir/feedback.json"
builder_report_path="$runtime_dir/builder-report.json"
verifier_report_path="$runtime_dir/verifier-report.json"
max_attempts="${CLASP_CODEX_LOOP_MAX_ATTEMPTS:-5}"
reset_baseline="${CLASP_CODEX_LOOP_RESET_BASELINE:-0}"
builder_timeout_seconds="${CLASP_CODEX_LOOP_BUILDER_TIMEOUT_SECONDS:-0}"
verifier_timeout_seconds="${CLASP_CODEX_LOOP_VERIFIER_TIMEOUT_SECONDS:-0}"
loop_mode="${CLASP_CODEX_LOOP_MODE:-auto}"

mkdir -p "$runs_root"

json_quote() {
  node -p 'JSON.stringify(process.argv[1])' "$1"
}

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

native_feedback_loop_program="$project_root/examples/swarm-native/FeedbackLoop.clasp"
resolved_native_claspc_bin=""

resolve_native_claspc_bin() {
  if [[ -n "$resolved_native_claspc_bin" ]]; then
    printf '%s\n' "$resolved_native_claspc_bin"
    return 0
  fi

  if [[ ! -f "$native_feedback_loop_program" ]]; then
    return 1
  fi

  if resolved_native_claspc_bin="$("$project_root/scripts/resolve-claspc.sh" 2>/dev/null)"; then
    printf '%s\n' "$resolved_native_claspc_bin"
    return 0
  fi

  resolved_native_claspc_bin=""
  return 1
}

native_loop_enabled() {
  case "$loop_mode" in
    legacy)
      return 1
      ;;
    native)
      resolve_native_claspc_bin >/dev/null
      ;;
    auto)
      resolve_native_claspc_bin >/dev/null 2>&1
      ;;
    *)
      echo "CLASP_CODEX_LOOP_MODE must be auto, native, or legacy" >&2
      exit 1
      ;;
  esac
}

materialize_native_history() {
  local report_path=""
  local attempt=""
  local attempt_dir=""

  rm -rf "$runs_root"
  mkdir -p "$runs_root"

  shopt -s nullglob
  for report_path in "$runtime_dir"/builder-*.json; do
    attempt="$(basename "$report_path" .json)"
    attempt="${attempt#builder-}"
    attempt_dir="$runs_root/attempt$attempt"
    mkdir -p "$attempt_dir"
    cp "$report_path" "$attempt_dir/builder-report.json"
  done
  for report_path in "$runtime_dir"/verifier-*.json; do
    attempt="$(basename "$report_path" .json)"
    attempt="${attempt#verifier-}"
    attempt_dir="$runs_root/attempt$attempt"
    mkdir -p "$attempt_dir"
    cp "$report_path" "$attempt_dir/verifier-report.json"
  done
  shopt -u nullglob

  if [[ -f "$feedback_path" ]]; then
    cp "$feedback_path" "$verifier_report_path"
  fi

  report_path="$(find "$runtime_dir" -maxdepth 1 -type f -name 'builder-*.json' | sort | tail -n 1 || true)"
  if [[ -n "$report_path" && -f "$report_path" ]]; then
    cp "$report_path" "$builder_report_path"
  fi
}

run_native_loop() {
  local claspc_bin=""
  local verdict=""
  local summary=""

  claspc_bin="$(resolve_native_claspc_bin)"

  env \
    CLASP_LOOP_TASK_FILE_JSON="$(json_quote "$task_file")" \
    CLASP_LOOP_WORKSPACE_JSON="$(json_quote "$workspace")" \
    CLASP_LOOP_CODEX_BIN_JSON="$(json_quote "${CLASP_LOOP_CODEX_BIN:-${CODEX_BIN:-codex}}")" \
    CLASP_LOOP_CODEX_MODEL_JSON="$(json_quote "${CODEX_MODEL:-gpt-5.4}")" \
    CLASP_LOOP_CODEX_REASONING_JSON="$(json_quote "${CODEX_REASONING_EFFORT:-medium}")" \
    CLASP_LOOP_CODEX_SANDBOX_JSON="$(json_quote "${CLASP_SWARM_CODEX_SANDBOX:-workspace-write}")" \
    CLASP_LOOP_MAX_ATTEMPTS_JSON="$max_attempts" \
    "$claspc_bin" run "$native_feedback_loop_program" -- "$runtime_dir" >/dev/null

  materialize_native_history

  if [[ ! -f "$feedback_path" ]]; then
    echo "native codex loop did not produce $feedback_path" >&2
    return 1
  fi

  verdict="$(verdict_of "$feedback_path")"
  summary="$(summary_of "$feedback_path")"
  echo "verifier verdict=$verdict summary=${summary:-"(none)"}"

  if [[ "$verdict" == "pass" ]]; then
    echo "loop passed via ordinary Clasp program"
    return 0
  fi

  echo "loop failed via ordinary Clasp program"
  return 1
}

run_legacy_loop() {
  local feedback_file=""
  local attempt=1
  local run_stamp=""
  local run_dir=""
  local builder_report=""
  local builder_log=""
  local verifier_report=""
  local verifier_log=""
  local builder_status=0
  local verifier_status=0
  local verdict=""
  local summary=""

  if [[ "$reset_baseline" == "1" || ! -f "$baseline_workspace/.snapshot-ready" ]]; then
    rm -rf "$baseline_workspace"
    mkdir -p "$baseline_workspace"
    copy_workspace "$workspace" "$baseline_workspace"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$baseline_workspace/.snapshot-ready"
  fi

  while :; do
    if [[ "$max_attempts" != "0" && "$attempt" -gt "$max_attempts" ]]; then
      echo "loop exhausted after $((attempt - 1)) attempts for $task_id" >&2
      return 1
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
    cp "$builder_report" "$builder_report_path"

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

    cp "$verifier_report" "$verifier_report_path"
    cp "$verifier_report" "$feedback_path"

    verdict="$(verdict_of "$verifier_report")"
    summary="$(summary_of "$verifier_report")"

    echo "verifier verdict=$verdict summary=${summary:-"(none)"}"

    if [[ "$verdict" == "pass" ]]; then
      echo "loop passed after $attempt attempt(s)"
      return 0
    fi

    feedback_file="$verifier_report"
    attempt=$((attempt + 1))
  done
}

exec 9>"$lock_file"
if ! flock -n 9; then
  echo "codex loop is already running for $task_id" >&2
  exit 1
fi

if native_loop_enabled; then
  run_native_loop
else
  run_legacy_loop
fi
