#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_root="$project_root/.clasp-agents"
tasks_root="$project_root/agents/tasks"
worktrees_root="$runtime_root/worktrees"
runs_root="$runtime_root/runs"
completed_root="$runtime_root/completed"
blocked_root="$runtime_root/blocked"
logs_root="$runtime_root/logs"
builder_workspace="$worktrees_root/builder"
verifier_workspace="$worktrees_root/verifier"
builder_branch="agents/autopilot"
current_task_file="$runtime_root/current-task.txt"
pid_file="$runtime_root/autopilot.pid"
retry_limit="${CLASP_AUTOPILOT_RETRY_LIMIT:-2}"
max_tasks="${CLASP_AUTOPILOT_MAX_TASKS:-0}"

mkdir -p "$worktrees_root" "$runs_root" "$completed_root" "$blocked_root" "$logs_root"

usage() {
  echo "usage: $0 [--list]" >&2
}

copy_workspace() {
  local src="$1"
  local dst="$2"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude '.git' "$src/" "$dst/"
  else
    find "$dst" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
    (
      cd "$src"
      tar --exclude=.git -cf - .
    ) | (
      cd "$dst"
      tar -xf -
    )
  fi
}

ensure_builder_worktree() {
  if [[ -e "$builder_workspace/.git" ]]; then
    return
  fi

  if git -C "$project_root" show-ref --verify --quiet "refs/heads/$builder_branch"; then
    git -C "$project_root" worktree add "$builder_workspace" "$builder_branch"
  else
    git -C "$project_root" worktree add -b "$builder_branch" "$builder_workspace" main
  fi
}

prepare_verifier_worktree() {
  local base_rev="$1"

  if [[ -e "$verifier_workspace/.git" ]]; then
    git -C "$project_root" worktree remove --force "$verifier_workspace"
  fi

  git -C "$project_root" worktree add --detach "$verifier_workspace" "$base_rev"
  copy_workspace "$builder_workspace" "$verifier_workspace"
}

mark_completed() {
  local task_id="$1"
  local commit_rev="$2"
  printf '%s\n' "$commit_rev" > "$completed_root/$task_id"
}

mark_blocked() {
  local task_id="$1"
  local report_file="$2"
  cp "$report_file" "$blocked_root/$task_id.json"
}

task_title() {
  sed -n '1s/^# //p' "$1"
}

workspace_dirty() {
  [[ -n "$(git -C "$1" status --short)" ]]
}

verdict_of() {
  node -e 'const fs=require("fs"); const p=process.argv[1]; const data=JSON.parse(fs.readFileSync(p,"utf8")); process.stdout.write(data.verdict);' "$1"
}

list_tasks() {
  for task_file in "$tasks_root"/*.md; do
    task_id="$(basename "$task_file" .md)"
    status="pending"
    if [[ -f "$completed_root/$task_id" ]]; then
      status="completed"
    elif [[ -f "$blocked_root/$task_id.json" ]]; then
      status="blocked"
    fi
    printf '%s\t%s\t%s\n' "$task_id" "$status" "$(task_title "$task_file")"
  done
}

if [[ $# -gt 1 ]]; then
  usage
  exit 1
fi

if [[ "${1:-}" == "--list" ]]; then
  list_tasks
  exit 0
fi

if workspace_dirty "$project_root"; then
  echo "base worktree must be clean before starting autopilot" >&2
  exit 1
fi

ensure_builder_worktree

if workspace_dirty "$builder_workspace"; then
  echo "builder worktree is dirty; clean or inspect $builder_workspace before continuing" >&2
  exit 1
fi

tasks_completed_this_run=0

for task_file in "$tasks_root"/*.md; do
  task_id="$(basename "$task_file" .md)"

  if [[ -f "$completed_root/$task_id" ]]; then
    continue
  fi

  if [[ -f "$blocked_root/$task_id.json" ]]; then
    echo "encountered previously blocked task $task_id; stopping" >&2
    exit 1
  fi

  printf '%s\n' "$task_id" > "$current_task_file"
  base_rev="$(git -C "$builder_workspace" rev-parse HEAD)"
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

    bash "$project_root/scripts/clasp-builder.sh" \
      "$task_file" \
      "$builder_workspace" \
      "$builder_report" \
      "$builder_log" \
      "${feedback_file:-}"

    prepare_verifier_worktree "$base_rev"

    bash "$project_root/scripts/clasp-verifier.sh" \
      "$task_file" \
      "$verifier_workspace" \
      "$base_rev" \
      "$verifier_report" \
      "$verifier_log"

    verdict="$(verdict_of "$verifier_report")"

    if [[ "$verdict" == "pass" ]]; then
      if workspace_dirty "$builder_workspace"; then
        git -C "$builder_workspace" add -A
        git -C "$builder_workspace" commit -m "Autopilot: $(task_title "$task_file")"
      fi

      commit_rev="$(git -C "$builder_workspace" rev-parse HEAD)"
      mark_completed "$task_id" "$commit_rev"
      tasks_completed_this_run=$((tasks_completed_this_run + 1))
      break
    fi

    feedback_file="$verifier_report"
    attempt=$((attempt + 1))
  done

  if [[ "$attempt" -gt "$retry_limit" ]]; then
    mark_blocked "$task_id" "$feedback_file"
    echo "task $task_id blocked after $retry_limit attempts; stopping" >&2
    exit 1
  fi

  if (( max_tasks > 0 && tasks_completed_this_run >= max_tasks )); then
    break
  fi
done

rm -f "$current_task_file" "$pid_file"
