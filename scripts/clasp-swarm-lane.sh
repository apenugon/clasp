#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$project_root/scripts/clasp-swarm-common.sh"

usage() {
  echo "usage: $0 [--list-tasks <lane-dir>] <lane-dir>" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

if [[ "${1:-}" == "--list-tasks" ]]; then
  if [[ $# -ne 2 ]]; then
    usage
    exit 1
  fi
  find "$2" -maxdepth 1 -type f -name '*.md' | sort
  exit 0
fi

lane_dir="$1"
wave_name="$(clasp_swarm_wave_name "$lane_dir")"
lane_name="$(clasp_swarm_lane_name "$lane_dir")"
runtime_root="$project_root/.clasp-swarm/$wave_name/$lane_name"
external_root="$(cd "$project_root/.." && pwd)"
worktrees_root="$external_root/.clasp-agent-worktrees/$(basename "$project_root")/$wave_name/$lane_name"
runs_root="$runtime_root/runs"
completed_root="$runtime_root/completed"
blocked_root="$runtime_root/blocked"
logs_root="$runtime_root/logs"
global_completed_root="$project_root/.clasp-swarm/completed"
current_task_file="$runtime_root/current-task.txt"
pid_file="$runtime_root/pid"
lock_file="$runtime_root/lane.lock"
merge_lock_file="$project_root/.clasp-swarm/merge.lock"
trunk_branch="${CLASP_SWARM_TRUNK_BRANCH:-agents/swarm-trunk}"
source_ref="${CLASP_SWARM_SOURCE_REF:-HEAD}"
branch_prefix="${CLASP_SWARM_BRANCH_PREFIX:-agents/swarm}"
retry_limit="${CLASP_SWARM_RETRY_LIMIT:-2}"
builder_timeout_seconds="${CLASP_SWARM_BUILDER_TIMEOUT_SECONDS:-900}"
verifier_timeout_seconds="${CLASP_SWARM_VERIFIER_TIMEOUT_SECONDS:-600}"
merge_timeout_seconds="${CLASP_SWARM_MERGE_TIMEOUT_SECONDS:-900}"
dependency_poll_seconds="${CLASP_SWARM_DEPENDENCY_POLL_SECONDS:-20}"
owns_runtime_state=0

mkdir -p \
  "$runtime_root" \
  "$worktrees_root" \
  "$runs_root" \
  "$completed_root" \
  "$blocked_root" \
  "$logs_root" \
  "$global_completed_root" \
  "$(dirname "$merge_lock_file")"

cleanup() {
  if [[ "$owns_runtime_state" == "1" ]]; then
    rm -f "$current_task_file" "$pid_file"
  fi
}

trap cleanup EXIT

run_with_timeout() {
  local timeout_seconds="$1"
  shift

  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=30s "${timeout_seconds}s" "$@"
  else
    "$@"
  fi
}

task_id_of() {
  basename "$1" .md
}

task_branch_of() {
  local task_id="$1"
  printf '%s/%s/%s/%s\n' "$branch_prefix" "$wave_name" "$lane_name" "$task_id"
}

task_worktree_of() {
  local task_id="$1"
  printf '%s/%s\n' "$worktrees_root" "$task_id"
}

task_file_list() {
  find "$lane_dir" -maxdepth 1 -type f -name '*.md' | sort
}

task_dependencies() {
  local task_file="$1"

  sed -n '/^## Dependencies$/,/^## /p' "$task_file" | grep -oE '[A-Z]{2}-[0-9]{3}' || true
}

dependency_is_complete() {
  local dependency_id="$1"
  [[ -f "$global_completed_root/$dependency_id" ]]
}

wait_for_dependencies() {
  local task_file="$1"
  local task_id="$2"
  local waiting_log="$logs_root/$task_id.waiting.log"
  local deps=()
  local unmet=()

  mapfile -t deps < <(task_dependencies "$task_file")

  if [[ "${#deps[@]}" -eq 0 ]]; then
    return 0
  fi

  while true; do
    unmet=()

    for dependency_id in "${deps[@]}"; do
      if ! dependency_is_complete "$dependency_id"; then
        unmet+=("$dependency_id")
      fi
    done

    if [[ "${#unmet[@]}" -eq 0 ]]; then
      rm -f "$waiting_log"
      return 0
    fi

    printf '%s waiting on %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "${unmet[*]}" > "$waiting_log"
    sleep "$dependency_poll_seconds"
  done
}

mark_completed() {
  local task_id="$1"
  local commit="$2"
  local stamp="$3"
  printf '%s\t%s\n' "$stamp" "$commit" > "$completed_root/$task_id"
  printf '%s\t%s\n' "$stamp" "$commit" > "$global_completed_root/$task_id"
}

mark_blocked() {
  local task_id="$1"
  local report_file="$2"
  cp "$report_file" "$blocked_root/$task_id.json"
}

clear_blocked() {
  local task_id="$1"
  rm -f "$blocked_root/$task_id.json"
}

remove_worktree_if_present() {
  local worktree_path="$1"

  if git -C "$project_root" worktree list --porcelain | grep -Fxq "worktree $worktree_path"; then
    git -C "$project_root" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
  fi

  rm -rf "$worktree_path"
}

prepare_task_worktree() {
  local task_id="$1"
  local task_branch
  local task_worktree

  task_branch="$(task_branch_of "$task_id")"
  task_worktree="$(task_worktree_of "$task_id")"

  remove_worktree_if_present "$task_worktree"

  git -C "$project_root" worktree add --force -B "$task_branch" "$task_worktree" "$trunk_branch" >/dev/null

  printf '%s\n' "$task_worktree"
}

prepare_baseline_worktree() {
  local baseline_worktree="$1"

  remove_worktree_if_present "$baseline_worktree"
  git -C "$project_root" worktree add --detach "$baseline_worktree" "$trunk_branch" >/dev/null
}

commit_task_changes() {
  local task_worktree="$1"
  local task_id="$2"

  git -C "$task_worktree" add -A

  if git -C "$task_worktree" diff --cached --quiet --ignore-submodules --exit-code; then
    return 0
  fi

  git -C "$task_worktree" \
    -c user.name="Clasp Swarm" \
    -c user.email="swarm@local" \
    commit -m "[$lane_name] $task_id" >/dev/null
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
const report = {
  verdict: "fail",
  summary,
  findings: [
    `${role} exited with code ${exitCode} while processing ${taskId}.`,
    ...(logTail.length > 0 ? [`Recent ${role} log lines:\n${logTail}`] : []),
  ],
  tests_run: [],
  follow_up: [
    "Retry the task from the current swarm trunk branch.",
    "If the failure repeats, split the task further or block the lane on this task.",
  ],
};
fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
EOF
}

archive_task_state() {
  local task_worktree="$1"
  local run_dir="$2"
  local task_branch="$3"

  git -C "$task_worktree" status --short > "$run_dir/git-status.txt" 2>&1 || true
  git -C "$task_worktree" diff > "$run_dir/task.diff" 2>&1 || true
  git -C "$task_worktree" rev-parse HEAD > "$run_dir/head.txt" 2>&1 || true
  printf '%s\n' "$task_branch" > "$run_dir/task-branch.txt"
}

integrate_task_branch() {
  local task_worktree="$1"
  local run_dir="$2"
  local integration_log="$run_dir/integration.log"
  local old_trunk
  local task_head

  exec 8>"$merge_lock_file"
  flock 8

  old_trunk="$(git -C "$project_root" rev-parse "$trunk_branch")"

  {
    task_head="$(git -C "$task_worktree" rev-parse HEAD)"

    if [[ "$task_head" != "$old_trunk" ]]; then
      git -C "$task_worktree" rebase "$trunk_branch"
      (
        cd "$task_worktree"
        bash scripts/verify-all.sh
      )
      task_head="$(git -C "$task_worktree" rev-parse HEAD)"
      git -C "$project_root" merge-base --is-ancestor "$old_trunk" "$task_head"
      git -C "$project_root" update-ref "refs/heads/$trunk_branch" "$task_head" "$old_trunk"
    else
      (
        cd "$task_worktree"
        bash scripts/verify-all.sh
      )
    fi

    printf '%s\n' "$(git -C "$project_root" rev-parse "$trunk_branch")"
  } >"$integration_log" 2>&1
}

ensure_trunk_branch() {
  if ! git -C "$project_root" show-ref --verify --quiet "refs/heads/$trunk_branch"; then
    git -C "$project_root" branch "$trunk_branch" "$source_ref"
  fi
}

exec 9>"$lock_file"
if ! flock -n 9; then
  echo "lane lock is already held for $lane_name" >&2
  exit 1
fi
owns_runtime_state=1

printf '%s\n' "$$" > "$pid_file"

ensure_trunk_branch

while IFS= read -r task_file; do
  task_id="$(task_id_of "$task_file")"

  if [[ -f "$completed_root/$task_id" ]]; then
    continue
  fi

  if [[ -f "$blocked_root/$task_id.json" ]]; then
    echo "lane $lane_name is blocked on $task_id" >&2
    break
  fi

  printf '%s\n' "$task_id" > "$current_task_file"
  wait_for_dependencies "$task_file" "$task_id"
  attempt=1
  feedback_file=""
  task_branch="$(task_branch_of "$task_id")"

  while (( attempt <= retry_limit )); do
    run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    run_dir="$runs_root/$run_stamp-$task_id-attempt$attempt"
    task_worktree="$(prepare_task_worktree "$task_id")"
    baseline_worktree="$run_dir/baseline-worktree"
    builder_report="$run_dir/builder-report.json"
    builder_log="$run_dir/builder-log.jsonl"
    verifier_report="$run_dir/verifier-report.json"
    verifier_log="$run_dir/verifier-log.jsonl"
    mkdir -p "$run_dir"
    prepare_baseline_worktree "$baseline_worktree"

    if run_with_timeout "$builder_timeout_seconds" \
      bash "$project_root/scripts/clasp-builder.sh" \
      "$task_file" \
      "$task_worktree" \
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
      archive_task_state "$task_worktree" "$run_dir" "$task_branch"
      feedback_file="$verifier_report"
      remove_worktree_if_present "$baseline_worktree"
      attempt=$((attempt + 1))
      continue
    fi

    commit_task_changes "$task_worktree" "$task_id"

    if run_with_timeout "$verifier_timeout_seconds" \
      bash "$project_root/scripts/clasp-verifier.sh" \
      "$task_file" \
      "$task_worktree" \
      "$baseline_worktree" \
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
      archive_task_state "$task_worktree" "$run_dir" "$task_branch"
      feedback_file="$verifier_report"
      remove_worktree_if_present "$baseline_worktree"
      attempt=$((attempt + 1))
      continue
    fi

    remove_worktree_if_present "$baseline_worktree"
    verdict="$(node -e 'const fs=require("fs"); const p=process.argv[1]; const data=JSON.parse(fs.readFileSync(p,"utf8")); process.stdout.write(data.verdict);' "$verifier_report")"

    if [[ "$verdict" != "pass" ]]; then
      archive_task_state "$task_worktree" "$run_dir" "$task_branch"
      feedback_file="$verifier_report"
      attempt=$((attempt + 1))
      continue
    fi

    if integrate_task_branch "$task_worktree" "$run_dir"; then
      integrated_commit="$(git -C "$project_root" rev-parse "$trunk_branch")"
      mark_completed "$task_id" "$integrated_commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      clear_blocked "$task_id"
      remove_worktree_if_present "$task_worktree"
      git -C "$project_root" branch -D "$task_branch" >/dev/null 2>&1 || true
      break
    else
      merge_exit="$?"
      write_failure_report \
        "$verifier_report" \
        "Merge gate or final verification failed before the task could be integrated." \
        "$run_dir/integration.log" \
        "$task_id" \
        "merge-gate" \
        "$merge_exit"
      archive_task_state "$task_worktree" "$run_dir" "$task_branch"
      feedback_file="$verifier_report"
      attempt=$((attempt + 1))
      continue
    fi
  done

  if (( attempt > retry_limit )); then
    mark_blocked "$task_id" "$feedback_file"
    echo "lane $lane_name blocked on $task_id after $retry_limit attempts" >&2
    break
  fi
done < <(task_file_list)
