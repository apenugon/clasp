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
  clasp_swarm_task_files "$2"
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
worktree_lock_file="$project_root/.clasp-swarm/worktree.lock"
trunk_branch="${CLASP_SWARM_TRUNK_BRANCH:-agents/swarm-trunk}"
main_branch="${CLASP_SWARM_MAIN_BRANCH:-main}"
source_ref="${CLASP_SWARM_SOURCE_REF:-HEAD}"
branch_prefix="${CLASP_SWARM_BRANCH_PREFIX:-agents/swarm}"
retry_limit="${CLASP_SWARM_RETRY_LIMIT:-3}"
builder_timeout_seconds="${CLASP_SWARM_BUILDER_TIMEOUT_SECONDS:-900}"
verifier_timeout_seconds="${CLASP_SWARM_VERIFIER_TIMEOUT_SECONDS:-7200}"
merge_timeout_seconds="${CLASP_SWARM_MERGE_TIMEOUT_SECONDS:-900}"
dependency_poll_seconds="${CLASP_SWARM_DEPENDENCY_POLL_SECONDS:-20}"
infra_retry_delay_seconds="${CLASP_SWARM_INFRA_RETRY_DELAY_SECONDS:-5}"
batch_filter="${CLASP_SWARM_BATCH:-}"
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
    release_lock "$lock_file"
  fi
}

trap cleanup EXIT

run_with_timeout() {
  local timeout_seconds="$1"
  shift

  if command -v timeout >/dev/null 2>&1; then
    bash -c 'exec 9>&-; exec timeout --signal=TERM --kill-after=30s "${1}s" "${@:2}"' _ \
      "$timeout_seconds" \
      "$@"
  else
    bash -c 'exec 9>&-; exec "$@"' _ "$@"
  fi
}

run_lane_subprocess() {
  local timeout_seconds="$1"
  shift

  run_with_timeout "$timeout_seconds" "$@"
}

lock_dir_for() {
  printf '%s.d\n' "$1"
}

clear_stale_lock() {
  local lock_path="$1"
  local lock_dir=""
  local owner_pid=""

  lock_dir="$(lock_dir_for "$lock_path")"

  if [[ ! -d "$lock_dir" || ! -f "$lock_dir/pid" ]]; then
    return 0
  fi

  owner_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"

  if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" >/dev/null 2>&1; then
    rm -f "$lock_dir/pid"
    rmdir "$lock_dir" >/dev/null 2>&1 || true
  fi
}

acquire_lock() {
  local lock_path="$1"
  local mode="${2:-wait}"
  local lock_dir=""

  lock_dir="$(lock_dir_for "$lock_path")"

  while ! mkdir "$lock_dir" 2>/dev/null; do
    clear_stale_lock "$lock_path"

    if mkdir "$lock_dir" 2>/dev/null; then
      break
    fi

    if [[ "$mode" == "try" ]]; then
      return 1
    fi

    sleep 0.1
  done

  printf '%s\n' "$$" > "$lock_dir/pid"
}

release_lock() {
  local lock_path="$1"
  local lock_dir=""

  lock_dir="$(lock_dir_for "$lock_path")"
  rm -f "$lock_dir/pid"
  rmdir "$lock_dir" >/dev/null 2>&1 || true
}

task_id_of() {
  basename "$1" .md
}

task_key_of() {
  clasp_swarm_completion_key "$1"
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
  clasp_swarm_task_files "$lane_dir"
}

canonicalize_dir_path() {
  local dir_path="$1"

  if [[ -d "$dir_path" ]]; then
    (
      cd "$dir_path"
      pwd -P
    )
    return 0
  fi

  printf '%s\n' "$dir_path"
}

task_worktree_registered() {
  local task_worktree="$1"
  local canonical_task_worktree=""

  canonical_task_worktree="$(canonicalize_dir_path "$task_worktree")"

  git -C "$project_root" worktree list --porcelain | grep -Fxq "worktree $canonical_task_worktree"
}

task_worktree_is_git_repo() {
  local task_worktree="$1"

  [[ -d "$task_worktree" ]] || return 1
  git -C "$task_worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

task_worktree_is_usable() {
  local task_worktree="$1"

  task_worktree_registered "$task_worktree" || return 1
  task_worktree_is_git_repo "$task_worktree"
}

task_id_from_run_dir() {
  local run_dir="$1"
  local base=""

  base="$(basename "$run_dir")"

  if [[ "$base" =~ ^[0-9]{8}T[0-9]{6}Z-(.+)-attempt[0-9]+$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

next_attempt_number_for_task() {
  local task_id="$1"
  local latest_run=""
  local latest_attempt=""
  local latest_run_trunk=""
  local current_trunk=""

  latest_run="$(clasp_swarm_latest_task_run_dir "$runs_root" "$task_id")"

  if [[ -z "$latest_run" ]]; then
    printf '1\n'
    return 0
  fi

  current_trunk="$(git -C "$project_root" rev-parse "$trunk_branch")"
  latest_run_trunk="$(cat "$latest_run/trunk-base.txt" 2>/dev/null || true)"

  if [[ -z "$latest_run_trunk" || "$latest_run_trunk" != "$current_trunk" ]]; then
    printf '1\n'
    return 0
  fi

  if latest_attempt="$(clasp_swarm_task_run_attempt "$latest_run" 2>/dev/null)"; then
    printf '%s\n' "$((latest_attempt + 1))"
  else
    printf '1\n'
  fi
}

resume_feedback_file=""

sync_completed_markers_from_global() {
  local task_file=""
  local task_id=""
  local git_commit=""
  local git_stamp=""

  while IFS= read -r task_file; do
    task_id="$(task_id_of "$task_file")"

    if clasp_swarm_completion_marker_exists "$completed_root" "$task_id"; then
      continue
    fi

    if clasp_swarm_completion_marker_exists "$global_completed_root" "$task_id"; then
      mark_completed \
        "$task_id" \
        "$(clasp_swarm_completion_commit "$global_completed_root" "$task_id")" \
        "$(clasp_swarm_completion_stamp "$global_completed_root" "$task_id")"
      continue
    fi

    if clasp_swarm_git_completion_marker_exists "$project_root" "$task_id" "$main_branch" "$trunk_branch"; then
      git_commit="$(clasp_swarm_git_completion_commit "$project_root" "$task_id" "$main_branch" "$trunk_branch")"
      git_stamp="$(clasp_swarm_git_completion_stamp "$project_root" "$task_id" "$main_branch" "$trunk_branch")"

      if [[ -n "$git_commit" && -n "$git_stamp" ]]; then
        mark_completed "$task_id" "$git_commit" "$git_stamp"
      fi
    fi
  done < <(task_file_list)
}

resume_incomplete_run() {
  local task_file="$1"
  local task_id="$2"
  local task_branch="$3"
  local run_dir=""
  local builder_report=""
  local builder_log=""
  local verifier_report=""
  local verifier_log=""
  local baseline_worktree=""
  local task_worktree=""
  local verifier_exit=""
  local baseline_exit=""
  local merge_exit=""
  local verdict=""
  local integrated_commit=""
  local current_trunk=""
  local run_trunk=""

  resume_feedback_file=""
  run_dir="$(clasp_swarm_latest_task_run_dir "$runs_root" "$task_id")"

  if [[ -z "$run_dir" ]]; then
    return 1
  fi

  builder_report="$run_dir/builder-report.json"
  builder_log="$run_dir/builder-log.jsonl"
  verifier_report="$run_dir/verifier-report.json"
  verifier_log="$run_dir/verifier-log.jsonl"
  baseline_worktree="$run_dir/baseline-worktree"
  task_worktree="$(task_worktree_of "$task_id")"

  if [[ ! -f "$builder_report" || -f "$verifier_report" ]]; then
    return 1
  fi

  if ! task_worktree_registered "$task_worktree"; then
    return 1
  fi

  if ! task_worktree_is_git_repo "$task_worktree"; then
    write_unusable_task_worktree_report \
      "$verifier_report" \
      "A previous builder run cannot be resumed because the task workspace is no longer a usable Git worktree." \
      "$builder_log" \
      "$task_id"
    archive_task_state "$task_worktree" "$run_dir" "$task_branch"
    remove_worktree_if_present "$task_worktree"
    remove_task_branch_if_present "$task_branch"
    cooldown_after_infra_failure
    resume_feedback_file="$verifier_report"
    return 2
  fi

  echo "resuming $task_id from $(basename "$run_dir")" >&2

  if ! sync_trunk_with_main "$verifier_log"; then
    verifier_exit="$?"
    write_failure_report \
      "$verifier_report" \
      "Main/trunk reconciliation failed while resuming verification." \
      "$verifier_log" \
      "$task_id" \
      "main-sync" \
      "$verifier_exit"
    archive_task_state "$task_worktree" "$run_dir" "$task_branch"
    resume_feedback_file="$verifier_report"
    return 2
  fi

  current_trunk="$(git -C "$project_root" rev-parse "$trunk_branch")"
  run_trunk="$(cat "$run_dir/trunk-base.txt" 2>/dev/null || true)"

  if [[ -z "$run_trunk" || "$run_trunk" != "$current_trunk" ]] || \
     ! git -C "$task_worktree" merge-base --is-ancestor "$current_trunk" HEAD; then
    echo "discarding stale run $(basename "$run_dir") for $task_id after trunk advanced to $current_trunk" >&2
    remove_worktree_if_present "$baseline_worktree"
    remove_worktree_if_present "$task_worktree"
    remove_task_branch_if_present "$task_branch"
    rm -rf "$run_dir"
    return 1
  fi

  if prepare_baseline_worktree "$baseline_worktree" 2>>"$verifier_log"; then
    :
  else
    baseline_exit="$?"
    write_failure_report \
      "$verifier_report" \
      "Baseline worktree preparation failed while resuming verification." \
      "$verifier_log" \
      "$task_id" \
      "baseline-prep" \
      "$baseline_exit"
    archive_task_state "$task_worktree" "$run_dir" "$task_branch"
    resume_feedback_file="$verifier_report"
    return 2
  fi

  commit_task_changes "$task_worktree" "$task_id"

  if run_lane_subprocess "$verifier_timeout_seconds" \
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
      "Verifier subagent infrastructure failed while resuming a completed builder run." \
      "$verifier_log" \
      "$task_id" \
      "verifier" \
      "$verifier_exit"
    archive_task_state "$task_worktree" "$run_dir" "$task_branch"
    resume_feedback_file="$verifier_report"
    remove_worktree_if_present "$baseline_worktree"
    return 2
  fi

  verdict="$(node -e 'const fs=require("fs"); const p=process.argv[1]; const data=JSON.parse(fs.readFileSync(p,"utf8")); process.stdout.write(data.verdict);' "$verifier_report")"

  if [[ "$verdict" != "pass" ]]; then
    remove_worktree_if_present "$baseline_worktree"
    archive_task_state "$task_worktree" "$run_dir" "$task_branch"
    resume_feedback_file="$verifier_report"
    return 2
  fi

  capture_workspace_snapshot "$baseline_worktree" "$run_dir/verified-baseline-snapshot"
  capture_workspace_snapshot "$task_worktree" "$run_dir/verified-workspace-snapshot"
  remove_worktree_if_present "$baseline_worktree"
  run_post_verifier_test_hook "$task_worktree" "$run_dir"

  if integrate_task_branch "$task_worktree" "$run_dir" "$task_id"; then
    integrated_commit="$(git -C "$project_root" rev-parse "$trunk_branch")"
    mark_completed "$task_id" "$integrated_commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    clear_blocked "$task_id"
    remove_worktree_if_present "$task_worktree"
    git -C "$project_root" branch -D "$task_branch" >/dev/null 2>&1 || true
    return 0
  fi

  merge_exit="$?"
  write_failure_report \
    "$verifier_report" \
    "Merge gate or final verification failed before the resumed task could be integrated." \
    "$run_dir/integration.log" \
    "$task_id" \
    "merge-gate" \
    "${merge_exit:-1}"
  archive_task_state "$task_worktree" "$run_dir" "$task_branch"
  resume_feedback_file="$verifier_report"
  return 2
}

dependency_is_complete() {
  local dependency_id="$1"
  clasp_swarm_completion_marker_exists "$global_completed_root" "$dependency_id"
}

dependency_label_is_complete() {
  local dependency_label="$1"
  clasp_swarm_batch_is_complete "$dependency_label" "$lane_dir" "$global_completed_root"
}

wait_for_dependencies() {
  local task_file="$1"
  local task_id="$2"
  local waiting_log="$logs_root/$task_id.waiting.log"
  local deps=()
  local deps_count=0
  local dependency_labels=()
  local dependency_labels_count=0
  local unmet=()
  local unmet_count=0
  local dependency_id=""
  local dependency_label=""

  while IFS= read -r dependency_id; do
    [[ -n "$dependency_id" ]] || continue
    deps+=("$dependency_id")
    deps_count=$((deps_count + 1))
  done < <(clasp_swarm_task_dependencies "$task_file")

  while IFS= read -r dependency_label; do
    [[ -n "$dependency_label" ]] || continue
    dependency_labels+=("$dependency_label")
    dependency_labels_count=$((dependency_labels_count + 1))
  done < <(clasp_swarm_task_dependency_labels "$task_file")

  if [[ "$deps_count" -eq 0 && "$dependency_labels_count" -eq 0 ]]; then
    return 0
  fi

  while true; do
    unmet=()
    unmet_count=0

    if [[ "$deps_count" -gt 0 ]]; then
      for dependency_id in "${deps[@]}"; do
        if ! dependency_is_complete "$dependency_id"; then
          unmet+=("$dependency_id")
          unmet_count=$((unmet_count + 1))
        fi
      done
    fi

    if [[ "$dependency_labels_count" -gt 0 ]]; then
      for dependency_label in "${dependency_labels[@]}"; do
        if ! dependency_label_is_complete "$dependency_label"; then
          unmet+=("label:$dependency_label")
          unmet_count=$((unmet_count + 1))
        fi
      done
    fi

    if [[ "$unmet_count" -eq 0 ]]; then
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
  local task_key

  task_key="$(task_key_of "$task_id")"
  printf '%s\t%s\n' "$stamp" "$commit" > "$completed_root/$task_key"
  printf '%s\t%s\n' "$stamp" "$commit" > "$global_completed_root/$task_key"
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

  acquire_lock "$worktree_lock_file"

  if git -C "$project_root" worktree list --porcelain | grep -Fxq "worktree $worktree_path"; then
    git -C "$project_root" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
  fi

  if [[ -e "$worktree_path" || -L "$worktree_path" ]]; then
    chflags -R nouchg,noschg "$worktree_path" >/dev/null 2>&1 || true
    chmod -R u+w "$worktree_path" >/dev/null 2>&1 || true
    rm -rf "$worktree_path" >/dev/null 2>&1 || true
  fi
  release_lock "$worktree_lock_file"
}

remove_task_branch_if_present() {
  local task_branch="$1"

  git -C "$project_root" branch -D "$task_branch" >/dev/null 2>&1 || true
}

cleanup_run_worktrees() {
  local run_dir="$1"
  local path=""

  for path in \
    "$run_dir/baseline-worktree" \
    "$run_dir/merge-baseline-worktree" \
    "$run_dir/accepted-snapshot-worktree"; do
    [[ -e "$path" ]] || continue
    remove_worktree_if_present "$path"
  done
}

repo_paths_for_root() {
  local root_path="$1"

  if git -C "$root_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$root_path" ls-files --cached --others --exclude-standard
    return 0
  fi

  if [[ ! -d "$root_path" ]]; then
    return 0
  fi

  (
    cd "$root_path"
    find . -mindepth 1 \( -type f -o -type l \) -print | sed 's#^\./##'
  )
}

capture_workspace_snapshot() {
  local src_root="$1"
  local snapshot_root="$2"
  local relative_path=""
  local path_list=""

  rm -rf "$snapshot_root"
  mkdir -p "$snapshot_root"

  path_list="$(mktemp)"
  repo_paths_for_root "$src_root" | sort -u > "$path_list"

  while IFS= read -r relative_path; do
    [[ -n "$relative_path" ]] || continue
    if ! worktree_path_exists "$src_root" "$relative_path"; then
      continue
    fi
    copy_relative_path_between_worktrees "$src_root" "$snapshot_root" "$relative_path"
  done < "$path_list"

  rm -f "$path_list"
}

run_post_verifier_test_hook() {
  local task_worktree="$1"
  local run_dir="$2"
  local hook_command="${CLASP_SWARM_TEST_POST_VERIFIER_HOOK:-}"

  [[ -n "$hook_command" ]] || return 0

  CLASP_SWARM_TEST_TASK_WORKTREE="$task_worktree" \
  CLASP_SWARM_TEST_RUN_DIR="$run_dir" \
  bash -lc "$hook_command"
}

garbage_collect_stale_runs() {
  local run_dir=""
  local task_id=""
  local task_branch=""
  local task_worktree=""
  local has_builder_report=0
  local has_verifier_report=0

  if [[ ! -d "$runs_root" ]]; then
    return 0
  fi

  while IFS= read -r run_dir; do
    [[ -n "$run_dir" ]] || continue

    cleanup_run_worktrees "$run_dir"

    has_builder_report=0
    has_verifier_report=0
    [[ -f "$run_dir/builder-report.json" ]] && has_builder_report=1
    [[ -f "$run_dir/verifier-report.json" ]] && has_verifier_report=1

    task_id="$(task_id_from_run_dir "$run_dir" 2>/dev/null || true)"
    if [[ -n "$task_id" ]]; then
      task_worktree="$(task_worktree_of "$task_id")"
      task_branch="$(task_branch_of "$task_id")"
    else
      task_worktree=""
      task_branch=""
    fi

    if [[ "$has_builder_report" == "1" && "$has_verifier_report" == "0" && -n "$task_worktree" ]]; then
      if ! task_worktree_is_usable "$task_worktree"; then
        remove_worktree_if_present "$task_worktree"
        remove_task_branch_if_present "$task_branch"
        rm -rf "$run_dir"
        continue
      fi
    fi

    if [[ "$has_builder_report" == "1" || "$has_verifier_report" == "1" ]]; then
      continue
    fi

    if [[ -n "$task_id" ]]; then
      remove_worktree_if_present "$task_worktree"
      remove_task_branch_if_present "$task_branch"
    fi

    rm -rf "$run_dir"
  done < <(find "$runs_root" -mindepth 1 -maxdepth 1 -type d | sort)
}

clear_git_worktree_locks() {
  rm -f "$project_root/.git/index.lock"
  find "$project_root/.git/worktrees" -maxdepth 2 -type f -name 'index.lock' -delete 2>/dev/null || true
}

prepare_git_worktree() {
  local add_args=("$@")
  local attempt=1
  local max_attempts=3

  while (( attempt <= max_attempts )); do
    acquire_lock "$worktree_lock_file"

    git -C "$project_root" worktree prune >/dev/null 2>&1 || true
    clear_git_worktree_locks

    if git -C "$project_root" worktree add "${add_args[@]}" >/dev/null; then
      release_lock "$worktree_lock_file"
      return 0
    fi

    release_lock "$worktree_lock_file"

    if (( attempt == max_attempts )); then
      return 1
    fi

    sleep 1
    attempt=$((attempt + 1))
  done
}

prepare_task_worktree() {
  local task_id="$1"
  local task_branch
  local task_worktree

  task_branch="$(task_branch_of "$task_id")"
  task_worktree="$(task_worktree_of "$task_id")"

  remove_worktree_if_present "$task_worktree"

  prepare_git_worktree --force -B "$task_branch" "$task_worktree" "$trunk_branch"

  printf '%s\n' "$task_worktree"
}

prepare_baseline_worktree() {
  local baseline_worktree="$1"

  remove_worktree_if_present "$baseline_worktree"
  prepare_git_worktree --detach "$baseline_worktree" "$trunk_branch"
}

write_task_feedback_artifact() {
  local task_worktree="$1"
  local task_id="$2"
  local builder_report="$3"
  local activation_task=""
  local feedback_path=""

  activation_task="$(clasp_swarm_feedback_activation_task)"
  if ! clasp_swarm_feedback_required "$project_root" "$activation_task"; then
    return 0
  fi

  feedback_path="$task_worktree/agents/feedback/$task_id.json"
  mkdir -p "$(dirname "$feedback_path")"

  node - <<'EOF' "$builder_report" "$feedback_path" "$task_id" "$activation_task"
const fs = require("fs");
const [reportPath, feedbackPath, taskId, activationTask] = process.argv.slice(2);
const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
if (!report.feedback || typeof report.feedback !== "object") {
  console.error(`missing builder feedback for ${taskId} after ${activationTask}`);
  process.exit(10);
}
const feedback = report.feedback;
if (typeof feedback.summary !== "string" || feedback.summary.trim().length === 0) {
  console.error(`feedback.summary is required for ${taskId}`);
  process.exit(11);
}
if (!Array.isArray(feedback.follow_ups)) {
  console.error(`feedback.follow_ups must be an array for ${taskId}`);
  process.exit(12);
}
const normalizeList = (value) => Array.isArray(value) ? value.map(String) : [];
const artifact = {
  task_id: taskId,
  summary: feedback.summary.trim(),
  ergonomics: normalizeList(feedback.ergonomics),
  follow_ups: normalizeList(feedback.follow_ups),
  warnings: normalizeList(feedback.warnings),
  files_touched: normalizeList(report.files_touched),
  tests_run: normalizeList(report.tests_run),
  residual_risks: normalizeList(report.residual_risks),
};
fs.writeFileSync(feedbackPath, `${JSON.stringify(artifact, null, 2)}\n`, "utf8");
EOF
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

write_unusable_task_worktree_report() {
  local report_file="$1"
  local summary="$2"
  local log_file="$3"
  local task_id="$4"

  node - <<'EOF' "$report_file" "$summary" "$log_file" "$task_id"
const fs = require("fs");
const [reportPath, summary, logPath, taskId] = process.argv.slice(2);
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
    `The task workspace for ${taskId} stopped being a usable Git worktree after the builder step.`,
    ...(logTail.length > 0 ? [`Recent builder log lines:\n${logTail}`] : []),
  ],
  tests_run: [],
  follow_up: [
    "Discard the broken task workspace and retry from the current swarm trunk branch.",
    "If the failure repeats, inspect the builder instructions and workspace materialization path.",
  ],
};
fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`, "utf8");
EOF
}

report_is_valid() {
  local report_file="$1"
  local report_kind="$2"

  node - <<'EOF' "$report_file" "$report_kind"
const fs = require("fs");
const [reportPath, kind] = process.argv.slice(2);

let raw = "";
try {
  raw = fs.readFileSync(reportPath, "utf8");
} catch (_) {
  process.exit(10);
}

if (raw.trim().length === 0) {
  process.exit(11);
}

let data;
try {
  data = JSON.parse(raw);
} catch (_) {
  process.exit(12);
}

const hasString = (value) => typeof value === "string" && value.trim().length > 0;
const hasArray = (value) => Array.isArray(value);

if (kind === "builder") {
  if (!hasString(data.summary) || !hasArray(data.files_touched) || !hasArray(data.tests_run) || !hasArray(data.residual_risks)) {
    process.exit(13);
  }
  process.exit(0);
}

if (kind === "verifier") {
  if (!hasString(data.verdict) || !hasString(data.summary) || !hasArray(data.findings) || !hasArray(data.tests_run) || !hasArray(data.follow_up)) {
    process.exit(14);
  }
  process.exit(0);
}

process.exit(15);
EOF
}

cooldown_after_infra_failure() {
  sleep "$infra_retry_delay_seconds"
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

worktree_repo_paths() {
  local worktree_path="$1"

  repo_paths_for_root "$worktree_path"
}

worktree_path_exists() {
  local worktree_path="$1"
  local relative_path="$2"

  [[ -e "$worktree_path/$relative_path" || -L "$worktree_path/$relative_path" ]]
}

worktree_path_matches() {
  local left_root="$1"
  local right_root="$2"
  local relative_path="$3"
  local left_path="$left_root/$relative_path"
  local right_path="$right_root/$relative_path"

  if [[ -L "$left_path" || -L "$right_path" ]]; then
    [[ -L "$left_path" && -L "$right_path" ]] || return 1
    [[ "$(readlink "$left_path")" == "$(readlink "$right_path")" ]]
    return 0
  fi

  [[ -e "$left_path" && -e "$right_path" ]] || return 1
  cmp -s "$left_path" "$right_path"
}

copy_relative_path_between_worktrees() {
  local src_root="$1"
  local dst_root="$2"
  local relative_path="$3"

  rm -rf "$dst_root/$relative_path"
  mkdir -p "$(dirname "$dst_root/$relative_path")"

  (
    cd "$src_root"
    tar -cf - -- "$relative_path"
  ) | (
    cd "$dst_root"
    tar -xf -
  )
}

apply_verified_workspace_delta() {
  local baseline_worktree="$1"
  local verified_worktree="$2"
  local accepted_worktree="$3"
  local path_list=""
  local relative_path=""
  local baseline_exists=0
  local verified_exists=0

  path_list="$(mktemp)"
  {
    worktree_repo_paths "$baseline_worktree"
    worktree_repo_paths "$verified_worktree"
  } | sort -u > "$path_list"

  while IFS= read -r relative_path; do
    [[ -n "$relative_path" ]] || continue

    baseline_exists=0
    verified_exists=0

    if worktree_path_exists "$baseline_worktree" "$relative_path"; then
      baseline_exists=1
    fi

    if worktree_path_exists "$verified_worktree" "$relative_path"; then
      verified_exists=1
    fi

    if [[ "$verified_exists" == "1" ]]; then
      if [[ "$baseline_exists" == "1" ]] && worktree_path_matches "$baseline_worktree" "$verified_worktree" "$relative_path"; then
        continue
      fi

      copy_relative_path_between_worktrees "$verified_worktree" "$accepted_worktree" "$relative_path"
      continue
    fi

    if [[ "$baseline_exists" == "1" ]]; then
      rm -rf "$accepted_worktree/$relative_path"
    fi
  done < "$path_list"

  rm -f "$path_list"
}

integrate_task_branch() {
  local task_worktree="$1"
  local run_dir="$2"
  local task_id="$3"
  local integration_log="$run_dir/integration.log"
  local merge_baseline_worktree="$run_dir/merge-baseline-worktree"
  local accepted_worktree="$run_dir/accepted-snapshot-worktree"
  local verified_baseline_snapshot="$run_dir/verified-baseline-snapshot"
  local verified_workspace_snapshot="$run_dir/verified-workspace-snapshot"
  local base_head
  local old_trunk
  local old_trunk_tree
  local task_head
  local pre_verify_tree
  local final_tree
  local accepted_head_tree
  local accepted_head
  local status=0

  acquire_lock "$merge_lock_file"

  set +e
  (
    set -euo pipefail

    ensure_trunk_branch
    clasp_swarm_reconcile_main_and_trunk "$project_root" "$main_branch" "$trunk_branch"
    base_head="$(git -C "$project_root" rev-parse "$main_branch")"
    old_trunk="$(git -C "$project_root" rev-parse "$trunk_branch")"
    old_trunk_tree="$(git -C "$project_root" rev-parse "$old_trunk^{tree}")"
    task_head="$(git -C "$task_worktree" rev-parse HEAD)"

    if [[ "$task_head" != "$base_head" ]]; then
      commit_task_changes "$task_worktree" "$task_id"
      git -C "$task_worktree" rebase "$main_branch"
      (
        cd "$task_worktree"
        bash scripts/verify-all.sh
      )
      task_head="$(git -C "$task_worktree" rev-parse HEAD)"
      git -C "$project_root" merge-base --is-ancestor "$base_head" "$task_head"
    else
      (
        cd "$task_worktree"
        bash scripts/verify-all.sh
      )
    fi

    prepare_baseline_worktree "$merge_baseline_worktree"
    prepare_baseline_worktree "$accepted_worktree"
    apply_verified_workspace_delta "$verified_baseline_snapshot" "$verified_workspace_snapshot" "$accepted_worktree"

    git -C "$accepted_worktree" add -A
    pre_verify_tree="$(git -C "$accepted_worktree" write-tree)"
    if [[ "$pre_verify_tree" == "$old_trunk_tree" ]]; then
      echo "accepted snapshot tree matched $old_trunk before final verification" >&2
      git -C "$accepted_worktree" status --short >&2 || true
      exit 12
    fi

    git -C "$accepted_worktree" \
      -c user.name="Clasp Swarm" \
      -c user.email="swarm@local" \
      commit -m "[$lane_name] $task_id" >/dev/null

    (
      cd "$accepted_worktree"
      bash scripts/verify-all.sh
    )

    git -C "$accepted_worktree" add -A
    final_tree="$(git -C "$accepted_worktree" write-tree)"
    if [[ "$final_tree" == "$old_trunk_tree" ]]; then
      echo "accepted snapshot tree matched $old_trunk after final verification" >&2
      git -C "$accepted_worktree" status --short >&2 || true
      exit 12
    fi

    accepted_head_tree="$(git -C "$accepted_worktree" rev-parse HEAD^{tree})"
    if [[ "$final_tree" != "$accepted_head_tree" ]]; then
      git -C "$accepted_worktree" \
        -c user.name="Clasp Swarm" \
        -c user.email="swarm@local" \
        commit --amend --no-edit >/dev/null
    fi

    accepted_head="$(git -C "$accepted_worktree" rev-parse HEAD)"
    if [[ "$accepted_head" == "$old_trunk" ]]; then
      echo "accepted snapshot did not advance beyond $old_trunk" >&2
      exit 12
    fi
    git -C "$project_root" merge --ff-only "$accepted_head"
    git -C "$project_root" update-ref "refs/heads/$trunk_branch" "$accepted_head" "$old_trunk"
    printf '%s\n' "$(git -C "$project_root" rev-parse "$main_branch")"
  ) >"$integration_log" 2>&1
  status=$?
  set -e

  remove_worktree_if_present "$merge_baseline_worktree"
  remove_worktree_if_present "$accepted_worktree"
  release_lock "$merge_lock_file"
  return "$status"
}

ensure_trunk_branch() {
  if ! git -C "$project_root" show-ref --verify --quiet "refs/heads/$trunk_branch"; then
    git -C "$project_root" branch "$trunk_branch" "$source_ref"
  fi
}

sync_trunk_with_main() {
  local sync_log="${1:-/dev/null}"
  local status=0

  acquire_lock "$merge_lock_file"

  set +e
  (
    set -euo pipefail

    ensure_trunk_branch
    clasp_swarm_reconcile_main_and_trunk "$project_root" "$main_branch" "$trunk_branch"
  ) >>"$sync_log" 2>&1
  status=$?
  set -e

  release_lock "$merge_lock_file"
  return "$status"
}

if ! acquire_lock "$lock_file" try; then
  echo "lane lock is already held for $lane_name" >&2
  exit 1
fi
owns_runtime_state=1

printf '%s\n' "$$" > "$pid_file"

ensure_trunk_branch
clasp_swarm_normalize_completion_dir "$completed_root"
clasp_swarm_normalize_completion_dir "$global_completed_root"
clasp_swarm_reconcile_completion_dir_with_git "$completed_root" "$project_root" "$main_branch" "$trunk_branch"
clasp_swarm_reconcile_completion_dir_with_git "$global_completed_root" "$project_root" "$main_branch" "$trunk_branch"
garbage_collect_stale_runs

while true; do
  sync_completed_markers_from_global

  selected_task="$(clasp_swarm_select_next_ready_task "$lane_dir" "$completed_root" "$global_completed_root" "$blocked_root" "$batch_filter" || true)"

  if [[ -z "$selected_task" ]]; then
    break
  fi

  if [[ "$selected_task" == __BLOCKED__:* ]]; then
    task_file="${selected_task#__BLOCKED__:}"
    task_id="$(task_id_of "$task_file")"
    echo "lane $lane_name is blocked on $task_id" >&2
    break
  fi

  if [[ "$selected_task" == __WAIT__:* ]]; then
    task_file="${selected_task#__WAIT__:}"
    task_id="$(task_id_of "$task_file")"
    printf '%s\n' "$task_id" > "$current_task_file"
    wait_for_dependencies "$task_file" "$task_id"
    continue
  fi

  task_file="$selected_task"
  task_id="$(task_id_of "$task_file")"
  printf '%s\n' "$task_id" > "$current_task_file"
  task_branch="$(task_branch_of "$task_id")"
  feedback_file=""
  attempt="$(next_attempt_number_for_task "$task_id")"

  if resume_incomplete_run "$task_file" "$task_id" "$task_branch"; then
    continue
  fi

  if [[ -n "$resume_feedback_file" ]]; then
    feedback_file="$resume_feedback_file"
  fi

  while true; do
    if clasp_swarm_retry_limit_is_bounded "$retry_limit" && (( attempt > retry_limit )); then
      mark_blocked "$task_id" "$feedback_file"
      echo "lane $lane_name blocked on $task_id after $retry_limit attempts" >&2
      break 2
    fi

    run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    run_dir="$runs_root/$run_stamp-$task_id-attempt$attempt"
    builder_report="$run_dir/builder-report.json"
    builder_log="$run_dir/builder-log.jsonl"
    verifier_report="$run_dir/verifier-report.json"
    verifier_log="$run_dir/verifier-log.jsonl"
    mkdir -p "$run_dir"
    baseline_worktree="$run_dir/baseline-worktree"

    if sync_trunk_with_main "$builder_log"; then
      git -C "$project_root" rev-parse "$trunk_branch" > "$run_dir/trunk-base.txt"
      :
    else
      sync_exit="$?"
      write_failure_report \
        "$verifier_report" \
        "Main/trunk reconciliation failed before the builder could run." \
        "$builder_log" \
        "$task_id" \
        "main-sync" \
        "$sync_exit"
      feedback_file="$verifier_report"
      attempt=$((attempt + 1))
      continue
    fi

    if task_worktree="$(prepare_task_worktree "$task_id" 2>>"$builder_log")"; then
      :
    else
      worktree_exit="$?"
      write_failure_report \
        "$verifier_report" \
        "Task worktree preparation failed before the builder could run." \
        "$builder_log" \
        "$task_id" \
        "worktree-prep" \
        "$worktree_exit"
      feedback_file="$verifier_report"
      attempt=$((attempt + 1))
      continue
    fi

    if prepare_baseline_worktree "$baseline_worktree" 2>>"$builder_log"; then
      :
    else
      baseline_exit="$?"
      write_failure_report \
        "$verifier_report" \
        "Baseline worktree preparation failed before the builder could run." \
        "$builder_log" \
        "$task_id" \
        "baseline-prep" \
        "$baseline_exit"
      remove_worktree_if_present "$task_worktree"
      feedback_file="$verifier_report"
      attempt=$((attempt + 1))
      continue
    fi

    if run_lane_subprocess "$builder_timeout_seconds" \
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
      cooldown_after_infra_failure
      attempt=$((attempt + 1))
      continue
    fi

    if report_is_valid "$builder_report" builder; then
      :
    else
      builder_report_exit="$?"
      write_failure_report \
        "$verifier_report" \
        "Builder exited without producing a valid builder report." \
        "$builder_log" \
        "$task_id" \
        "builder-report" \
        "$builder_report_exit"
      archive_task_state "$task_worktree" "$run_dir" "$task_branch"
      feedback_file="$verifier_report"
      remove_worktree_if_present "$baseline_worktree"
      cooldown_after_infra_failure
      attempt=$((attempt + 1))
      continue
    fi

    if task_worktree_is_usable "$task_worktree"; then
      :
    else
      write_unusable_task_worktree_report \
        "$verifier_report" \
        "Builder completed, but the task workspace is no longer a usable Git worktree." \
        "$builder_log" \
        "$task_id"
      archive_task_state "$task_worktree" "$run_dir" "$task_branch"
      feedback_file="$verifier_report"
      remove_worktree_if_present "$baseline_worktree"
      remove_worktree_if_present "$task_worktree"
      remove_task_branch_if_present "$task_branch"
      cooldown_after_infra_failure
      attempt=$((attempt + 1))
      continue
    fi

    if write_task_feedback_artifact "$task_worktree" "$task_id" "$builder_report" 2>>"$builder_log"; then
      :
    else
      feedback_exit="$?"
      write_failure_report \
        "$verifier_report" \
        "Builder feedback artifact generation failed before verification could run." \
        "$builder_log" \
        "$task_id" \
        "builder-feedback" \
        "$feedback_exit"
      archive_task_state "$task_worktree" "$run_dir" "$task_branch"
      feedback_file="$verifier_report"
      remove_worktree_if_present "$baseline_worktree"
      cooldown_after_infra_failure
      attempt=$((attempt + 1))
      continue
    fi

    commit_task_changes "$task_worktree" "$task_id"

    if run_lane_subprocess "$verifier_timeout_seconds" \
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
      cooldown_after_infra_failure
      attempt=$((attempt + 1))
      continue
    fi

    if report_is_valid "$verifier_report" verifier; then
      :
    else
      verifier_report_exit="$?"
      write_failure_report \
        "$verifier_report" \
        "Verifier exited without producing a valid verifier report." \
        "$verifier_log" \
        "$task_id" \
        "verifier-report" \
        "$verifier_report_exit"
      archive_task_state "$task_worktree" "$run_dir" "$task_branch"
      feedback_file="$verifier_report"
      cooldown_after_infra_failure
      attempt=$((attempt + 1))
      continue
    fi

    verdict="$(node -e 'const fs=require("fs"); const p=process.argv[1]; const data=JSON.parse(fs.readFileSync(p,"utf8")); process.stdout.write(data.verdict);' "$verifier_report")"

    if [[ "$verdict" != "pass" ]]; then
      remove_worktree_if_present "$baseline_worktree"
      archive_task_state "$task_worktree" "$run_dir" "$task_branch"
      feedback_file="$verifier_report"
      attempt=$((attempt + 1))
      continue
    fi

    capture_workspace_snapshot "$baseline_worktree" "$run_dir/verified-baseline-snapshot"
    capture_workspace_snapshot "$task_worktree" "$run_dir/verified-workspace-snapshot"
    remove_worktree_if_present "$baseline_worktree"
    run_post_verifier_test_hook "$task_worktree" "$run_dir"

    merge_exit=1
    if integrate_task_branch "$task_worktree" "$run_dir" "$task_id"; then
      integrated_commit="$(git -C "$project_root" rev-parse "$trunk_branch")"
      mark_completed "$task_id" "$integrated_commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      clear_blocked "$task_id"
      remove_worktree_if_present "$task_worktree"
      remove_task_branch_if_present "$task_branch"
      break
    else
      merge_exit="$?"
      write_failure_report \
        "$verifier_report" \
        "Merge gate or final verification failed before the task could be integrated." \
        "$run_dir/integration.log" \
        "$task_id" \
        "merge-gate" \
        "${merge_exit:-1}"
      archive_task_state "$task_worktree" "$run_dir" "$task_branch"
      feedback_file="$verifier_report"
      attempt=$((attempt + 1))
      continue
    fi
  done

done
