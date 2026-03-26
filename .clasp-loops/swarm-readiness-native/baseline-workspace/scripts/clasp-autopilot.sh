#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_root="$project_root/.clasp-agents"
tasks_root="$project_root/agents/tasks"
external_root="$(cd "$project_root/.." && pwd)"
workspaces_root="$external_root/.clasp-agent-workspaces/$(basename "$project_root")"
runs_root="$runtime_root/runs"
completed_root="$runtime_root/completed"
blocked_root="$runtime_root/blocked"
generated_tasks_root="$runtime_root/generated-tasks"
logs_root="$runtime_root/logs"
snapshot_workspace="$runtime_root/verified-snapshot"
builder_workspace="$workspaces_root/builder"
verifier_workspace="$workspaces_root/verifier"
current_task_file="$runtime_root/current-task.txt"
pid_file="$runtime_root/autopilot.pid"
lock_file="$runtime_root/autopilot.lock"
retry_limit="${CLASP_AUTOPILOT_RETRY_LIMIT:-2}"
max_tasks="${CLASP_AUTOPILOT_MAX_TASKS:-0}"
allow_dirty_root="${CLASP_AUTOPILOT_ALLOW_DIRTY_ROOT:-0}"
reset_snapshot="${CLASP_AUTOPILOT_RESET_SNAPSHOT:-0}"
builder_timeout_seconds="${CLASP_AUTOPILOT_BUILDER_TIMEOUT_SECONDS:-900}"
verifier_timeout_seconds="${CLASP_AUTOPILOT_VERIFIER_TIMEOUT_SECONDS:-600}"
owns_runtime_state=0

mkdir -p \
  "$workspaces_root" \
  "$runs_root" \
  "$completed_root" \
  "$blocked_root" \
  "$generated_tasks_root" \
  "$logs_root" \
  "$snapshot_workspace"

usage() {
  echo "usage: $0 [--list]" >&2
}

cleanup() {
  if [[ "$owns_runtime_state" == "1" ]]; then
    rm -f "$current_task_file" "$pid_file"
  fi
}

trap cleanup EXIT

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

  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=30s "${timeout_seconds}s" "$@"
  else
    "$@"
  fi
}

ensure_snapshot() {
  if [[ "$reset_snapshot" == "1" ]] && [[ -d "$snapshot_workspace" ]]; then
    rm -rf "$snapshot_workspace"
    mkdir -p "$snapshot_workspace"
  fi

  if [[ ! -f "$snapshot_workspace/.snapshot-ready" ]]; then
    copy_workspace "$project_root" "$snapshot_workspace"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$snapshot_workspace/.snapshot-ready"
  fi
}

reset_builder_workspace() {
  copy_workspace "$snapshot_workspace" "$builder_workspace"
}

prepare_verifier_workspace() {
  copy_workspace "$builder_workspace" "$verifier_workspace"
}

mark_completed() {
  local task_id="$1"
  local stamp="$2"
  printf '%s\n' "$stamp" > "$completed_root/$task_id"
}

mark_blocked() {
  local task_id="$1"
  local report_file="$2"
  cp "$report_file" "$blocked_root/$task_id.json"
}

clear_blocked() {
  local task_id="$1"
  if [[ -f "$blocked_root/$task_id.json" ]]; then
    rm -f "$blocked_root/$task_id.json"
  fi
}

archive_builder_workspace() {
  local archive_dir="$1"
  mkdir -p "$archive_dir"
  copy_workspace "$builder_workspace" "$archive_dir"
}

task_title() {
  sed -n '1s/^# //p' "$1"
}

task_id_of() {
  basename "$1" .md
}

base_task_id_of() {
  local task_id="$1"
  if [[ "$task_id" == *"--workaround"* ]]; then
    printf '%s\n' "${task_id%%--workaround*}"
  else
    printf '%s\n' "$task_id"
  fi
}

is_workaround_task() {
  local task_id="$1"
  [[ "$task_id" == *"--workaround"* ]]
}

canonical_workaround_task_id_of() {
  local task_id="$1"
  local base_task_id
  base_task_id="$(base_task_id_of "$task_id")"
  printf '%s\n' "${base_task_id}--workaround"
}

canonical_generated_task_file_of() {
  local task_id="$1"
  printf '%s/%s.md\n' "$generated_tasks_root" "$(canonical_workaround_task_id_of "$task_id")"
}

workspace_dirty() {
  ! diff -qr "$snapshot_workspace" "$builder_workspace" >/dev/null 2>&1
}

verdict_of() {
  node -e 'const fs=require("fs"); const p=process.argv[1]; const data=JSON.parse(fs.readFileSync(p,"utf8")); process.stdout.write(data.verdict);' "$1"
}

write_failure_report() {
  local report_file="$1"
  local summary="$2"
  local log_file="$3"
  local task_id="$4"
  local role="$5"
  local exit_code="$6"

  node - <<'EOF' "$report_file" "$summary" "$log_file" "$task_id" "$role" "$exit_code"
const fs = require("fs");
const [reportPath, summary, logPath, taskId, role, exitCode] = process.argv.slice(2);
let logTail = "";
const truncate = (value, max) =>
  value.length > max ? `${value.slice(0, max - 3)}...` : value;
try {
  const text = fs.readFileSync(logPath, "utf8");
  logTail = text
    .split(/\r?\n/)
    .filter(Boolean)
    .slice(-6)
    .map((line) => truncate(line, 220))
    .join("\n");
} catch (_) {
  logTail = "";
}
const findings = [
  `${role} exited with code ${exitCode} while processing ${taskId}.`,
];
if (logTail.length > 0) {
  findings.push(`Recent ${role} log lines:\n${logTail}`);
}
const report = {
  verdict: "fail",
  summary,
  findings,
  tests_run: [],
  follow_up: [
    "Retry the same task from the current verified snapshot.",
    "If the failure repeats, reduce the task scope or work around the reported failure mode.",
  ],
};
fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
EOF
}

has_pending_workaround() {
  local task_id="$1"
  local workaround_task_file
  local workaround_task_id

  workaround_task_file="$(canonical_generated_task_file_of "$task_id")"
  workaround_task_id="$(canonical_workaround_task_id_of "$task_id")"

  if [[ -f "$workaround_task_file" ]] && [[ ! -f "$completed_root/$workaround_task_id" ]]; then
    return 0
  fi

  return 1
}

clear_workaround_state() {
  local task_id="$1"
  local base_task_id
  local workaround_task_id

  base_task_id="$(base_task_id_of "$task_id")"
  workaround_task_id="$(canonical_workaround_task_id_of "$base_task_id")"

  rm -f \
    "$generated_tasks_root/$workaround_task_id.md" \
    "$blocked_root/$workaround_task_id.json" \
    "$completed_root/$workaround_task_id"
}

create_workaround_task() {
  local task_file="$1"
  local report_file="$2"
  local task_id
  local base_task_id
  local workaround_id
  local output_file

  task_id="$(task_id_of "$task_file")"
  base_task_id="$(base_task_id_of "$task_id")"

  if is_workaround_task "$task_id"; then
    return 1
  fi

  workaround_id="$(canonical_workaround_task_id_of "$task_id")"
  output_file="$generated_tasks_root/$workaround_id.md"

  rm -f "$output_file" "$blocked_root/$workaround_id.json" "$completed_root/$workaround_id"

  node - <<'EOF' "$task_id" "$base_task_id" "$workaround_id" "$report_file" > "$output_file"
const fs = require("fs");
const [taskId, baseTaskId, workaroundId, reportPath] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const truncate = (value, max) =>
  value.length > max ? `${value.slice(0, max - 3)}...` : value;
const findings = (Array.isArray(report.findings) ? report.findings : [])
  .slice(0, 6)
  .map((item) => truncate(String(item), 220));
const followUp = (Array.isArray(report.follow_up) ? report.follow_up : [])
  .slice(0, 6)
  .map((item) => truncate(String(item), 200));
const testsRun = (Array.isArray(report.tests_run) ? report.tests_run : [])
  .slice(0, 6)
  .map((item) => truncate(String(item), 180));

console.log(`# ${workaroundId}`);
console.log("");
console.log("## Goal");
console.log("");
console.log(`Unblock \`${baseTaskId}\` by addressing the concrete verifier failure below in the smallest possible change set.`);
console.log("");
console.log("## Verifier Summary");
console.log("");
console.log(truncate(report.summary || "No summary provided.", 320));
console.log("");
console.log("## Findings");
console.log("");
for (const item of findings) {
  console.log(`- ${item}`);
}
if (findings.length === 0) {
  console.log("- No structured findings were provided.");
}
console.log("");
console.log("## Follow Up");
console.log("");
for (const item of followUp) {
  console.log(`- ${item}`);
}
if (followUp.length === 0) {
  console.log("- Reduce scope and isolate the failing behavior so the parent task can be retried.");
}
console.log("");
console.log("## Acceptance");
console.log("");
console.log("- `bash scripts/verify-all.sh` passes");
console.log(`- The parent task \`${baseTaskId}\` should become retryable after this workaround lands`);
console.log("");
console.log("## Context");
console.log("");
console.log(`- Generated from failing task \`${taskId}\``);
for (const item of testsRun) {
  console.log(`- ${item}`);
}
EOF

  printf '%s\n' "$output_file"
}

task_file_list() {
  find "$tasks_root" "$generated_tasks_root" -maxdepth 1 -type f -name '*.md' | sort
}

list_tasks() {
  while IFS= read -r task_file; do
    local task_id
    local status
    task_id="$(task_id_of "$task_file")"
    status="pending"
    if [[ -f "$completed_root/$task_id" ]]; then
      status="completed"
    elif [[ -f "$blocked_root/$task_id.json" ]]; then
      status="blocked"
    fi
    printf '%s\t%s\t%s\n' "$task_id" "$status" "$(task_title "$task_file")"
  done < <(task_file_list)
}

if [[ $# -gt 1 ]]; then
  usage
  exit 1
fi

if [[ "${1:-}" == "--list" ]]; then
  list_tasks
  exit 0
fi

exec 9>"$lock_file"
if ! flock -n 9; then
  echo "autopilot lock is already held" >&2
  exit 1
fi
owns_runtime_state=1

ensure_snapshot
reset_builder_workspace

tasks_completed_this_run=0

while :; do
  restart_scan=0
  saw_incomplete_task=0
  made_progress_this_scan=0

  while IFS= read -r task_file; do
    task_id="$(task_id_of "$task_file")"

    if [[ -f "$completed_root/$task_id" ]]; then
      continue
    fi

    saw_incomplete_task=1

    if [[ -f "$blocked_root/$task_id.json" ]]; then
      if is_workaround_task "$task_id"; then
        echo "workaround task $task_id is blocked; leaving it blocked and continuing" >&2
        continue
      fi

      if has_pending_workaround "$task_id"; then
        echo "waiting on existing workaround for $task_id" >&2
        continue
      fi

      if create_workaround_task "$task_file" "$blocked_root/$task_id.json" >/dev/null; then
        echo "generated workaround task for $task_id" >&2
        restart_scan=1
        break
      fi

      echo "skipping exhausted blocked task $task_id" >&2
      continue
    fi

    printf '%s\n' "$task_id" > "$current_task_file"
    feedback_file=""
    attempt=1

    while (( attempt <= retry_limit )); do
      run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
      run_dir="$runs_root/$run_stamp-$task_id-attempt$attempt"
      mkdir -p "$run_dir"

      builder_report="$run_dir/builder-report.json"
      builder_log="$run_dir/builder-log.jsonl"
      verifier_report="$run_dir/verifier-report.json"
      verifier_log="$run_dir/verifier-log.jsonl"

      if run_with_timeout "$builder_timeout_seconds" \
        bash "$project_root/scripts/clasp-builder.sh" \
        "$task_file" \
        "$builder_workspace" \
        "$builder_report" \
        "$builder_log" \
        "${feedback_file:-}"; then
        :
      else
        builder_exit="$?"
        write_failure_report \
          "$verifier_report" \
          "Builder subagent infrastructure failed before verification could run." \
          "$builder_log" \
          "$task_id" \
          "builder" \
          "$builder_exit"
        feedback_file="$verifier_report"
        attempt=$((attempt + 1))
        reset_builder_workspace
        continue
      fi

      prepare_verifier_workspace

      if run_with_timeout "$verifier_timeout_seconds" \
        bash "$project_root/scripts/clasp-verifier.sh" \
        "$task_file" \
        "$verifier_workspace" \
        "$snapshot_workspace" \
        "$verifier_report" \
        "$verifier_log"; then
        :
      else
        verifier_exit="$?"
        write_failure_report \
          "$verifier_report" \
          "Verifier subagent infrastructure failed before a verdict was produced." \
          "$verifier_log" \
          "$task_id" \
          "verifier" \
          "$verifier_exit"
        feedback_file="$verifier_report"
        attempt=$((attempt + 1))
        reset_builder_workspace
        continue
      fi

      verdict="$(verdict_of "$verifier_report")"

      if [[ "$verdict" == "pass" ]]; then
        if workspace_dirty; then
          copy_workspace "$builder_workspace" "$snapshot_workspace"
          date -u +%Y-%m-%dT%H:%M:%SZ > "$snapshot_workspace/.snapshot-ready"
        fi

        mark_completed "$task_id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        clear_blocked "$(base_task_id_of "$task_id")"
        clear_workaround_state "$task_id"
        tasks_completed_this_run=$((tasks_completed_this_run + 1))
        made_progress_this_scan=1
        break
      fi

      feedback_file="$verifier_report"
      attempt=$((attempt + 1))
    done

    if [[ "$attempt" -gt "$retry_limit" ]]; then
      mark_blocked "$task_id" "$feedback_file"
      archive_builder_workspace "$run_dir/failed-builder-workspace"
      reset_builder_workspace

      if is_workaround_task "$task_id"; then
        echo "workaround task $task_id blocked after $retry_limit attempts; continuing to later tasks" >&2
        continue
      fi

      if create_workaround_task "$task_file" "$feedback_file" >/dev/null; then
        echo "task $task_id blocked after $retry_limit attempts; generated workaround and continuing" >&2
        restart_scan=1
        break
      else
        echo "task $task_id blocked after $retry_limit attempts; workaround budget exhausted, continuing" >&2
      fi
      continue
    fi

    if (( max_tasks > 0 && tasks_completed_this_run >= max_tasks )); then
      break 2
    fi
  done < <(task_file_list)

  if (( restart_scan )); then
    continue
  fi

  if (( saw_incomplete_task == 0 )); then
    break
  fi

  if (( made_progress_this_scan )); then
    continue
  fi

  echo "no runnable tasks remain; stopping autopilot" >&2
  break
done
