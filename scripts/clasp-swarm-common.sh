#!/usr/bin/env bash
set -euo pipefail

clasp_swarm_project_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd
}

clasp_swarm_default_wave() {
  printf '%s\n' "${CLASP_SWARM_DEFAULT_WAVE:-full}"
}

clasp_swarm_wave_dir() {
  local wave_name="$1"
  local project_root="$2"
  printf '%s/agents/swarm/%s\n' "$project_root" "$wave_name"
}

clasp_swarm_lane_dirs() {
  local wave_name="$1"
  local project_root="$2"
  local wave_dir

  wave_dir="$(clasp_swarm_wave_dir "$wave_name" "$project_root")"

  if [[ ! -d "$wave_dir" ]]; then
    return 0
  fi

  find "$wave_dir" -mindepth 1 -maxdepth 1 -type d | sort
}

clasp_swarm_task_files() {
  local lane_dir="$1"

  find "$lane_dir" -maxdepth 1 -type f -name '*.md' | sort
}

clasp_swarm_lane_name() {
  basename "$1"
}

clasp_swarm_wave_name() {
  basename "$(dirname "$1")"
}

clasp_swarm_task_key() {
  local raw="${1##*/}"
  raw="${raw%.md}"

  if [[ "$raw" =~ ^([A-Z]{2,3}-[0-9]{3})($|-) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

clasp_swarm_completion_key() {
  local raw="${1##*/}"
  raw="${raw%.md}"
  local key=""

  if key="$(clasp_swarm_task_key "$raw" 2>/dev/null)"; then
    printf '%s\n' "$key"
  else
    printf '%s\n' "$raw"
  fi
}

clasp_swarm_completion_marker_exists() {
  local markers_dir="$1"
  local task_ref="$2"
  local key

  key="$(clasp_swarm_completion_key "$task_ref")"

  if [[ -f "$markers_dir/$key" ]]; then
    return 0
  fi

  local matches=()

  shopt -s nullglob
  matches=("$markers_dir/$key-"*)
  shopt -u nullglob

  [[ "${#matches[@]}" -gt 0 ]]
}

clasp_swarm_normalize_completion_dir() {
  local markers_dir="$1"
  local path=""
  local base=""
  local key=""
  local canonical_path=""

  mkdir -p "$markers_dir"

  shopt -s nullglob
  for path in "$markers_dir"/*; do
    [[ -f "$path" ]] || continue
    base="$(basename "$path")"
    key="$(clasp_swarm_completion_key "$base")"
    canonical_path="$markers_dir/$key"

    if [[ "$path" == "$canonical_path" ]]; then
      continue
    fi

    if [[ -e "$canonical_path" ]]; then
      rm -f "$path"
    else
      mv "$path" "$canonical_path"
    fi
  done
  shopt -u nullglob
}

clasp_swarm_completion_marker_field() {
  local markers_dir="$1"
  local task_ref="$2"
  local field_index="$3"
  local key=""
  local marker_path=""

  key="$(clasp_swarm_completion_key "$task_ref")"
  marker_path="$markers_dir/$key"

  if [[ ! -f "$marker_path" ]]; then
    return 1
  fi

  awk -F '\t' -v idx="$field_index" 'NR == 1 { print $idx }' "$marker_path"
}

clasp_swarm_completion_stamp() {
  clasp_swarm_completion_marker_field "$1" "$2" 1
}

clasp_swarm_completion_commit() {
  clasp_swarm_completion_marker_field "$1" "$2" 2
}

clasp_swarm_feedback_activation_task() {
  printf '%s\n' "${CLASP_SWARM_FEEDBACK_AFTER_TASK:-SH-014}"
}

clasp_swarm_feedback_required() {
  local project_root="$1"
  local activation_task="${2:-$(clasp_swarm_feedback_activation_task)}"
  local completed_root="$project_root/.clasp-swarm/completed"

  clasp_swarm_completion_marker_exists "$completed_root" "$activation_task"
}

clasp_swarm_feedback_dir() {
  local project_root="$1"
  printf '%s/agents/feedback\n' "$project_root"
}

clasp_swarm_feedback_path() {
  local project_root="$1"
  local task_ref="$2"
  local task_key=""

  task_key="$(clasp_swarm_completion_key "$task_ref")"
  printf '%s/%s.json\n' "$(clasp_swarm_feedback_dir "$project_root")" "$task_key"
}

clasp_swarm_latest_task_run_dir() {
  local runs_root="$1"
  local task_ref="$2"
  local key=""
  local latest=""

  key="$(clasp_swarm_completion_key "$task_ref")"

  if [[ ! -d "$runs_root" ]]; then
    return 0
  fi

  latest="$(
    find "$runs_root" -maxdepth 1 -mindepth 1 -type d -name "*-$key-*" | sort | tail -n 1
  )"

  if [[ -n "$latest" ]]; then
    printf '%s\n' "$latest"
  fi
}

clasp_swarm_task_run_attempt() {
  local run_dir="$1"
  local base=""

  base="$(basename "$run_dir")"

  if [[ "$base" =~ -attempt([0-9]+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

clasp_swarm_retry_limit_is_bounded() {
  local retry_limit="$1"

  [[ "$retry_limit" =~ ^[0-9]+$ ]] && (( retry_limit > 0 ))
}

clasp_swarm_spawn_detached() {
  local log_file="$1"
  shift

  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >"$log_file" 2>&1 < /dev/null &
  elif command -v nohup >/dev/null 2>&1; then
    nohup "$@" >"$log_file" 2>&1 < /dev/null &
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$log_file" "$@" <<'PY'
import os
import subprocess
import sys

log_path = sys.argv[1]
command = sys.argv[2:]

with open(log_path, "ab", buffering=0) as log_handle, open(os.devnull, "rb") as null_stdin:
    process = subprocess.Popen(
        command,
        stdin=null_stdin,
        stdout=log_handle,
        stderr=log_handle,
        start_new_session=True,
        close_fds=True,
    )

print(process.pid)
PY
    return 0
  else
    "$@" >"$log_file" 2>&1 < /dev/null &
  fi

  printf '%s\n' "$!"
}

clasp_swarm_task_dependencies() {
  local task_file="$1"

  sed -n '/^## Dependencies$/,/^## /p' "$task_file" | grep -oE '[A-Z]{2,3}-[0-9]{3}' || true
}

clasp_swarm_task_dependencies_met() {
  local task_file="$1"
  local completed_root="$2"
  local dep=""

  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    if ! clasp_swarm_completion_marker_exists "$completed_root" "$dep"; then
      return 1
    fi
  done < <(clasp_swarm_task_dependencies "$task_file")

  return 0
}

clasp_swarm_select_next_ready_task() {
  local lane_dir="$1"
  local completed_root="$2"
  local global_completed_root="$3"
  local blocked_root="$4"
  local task_file=""
  local task_id=""
  local first_pending=""

  while IFS= read -r task_file; do
    task_id="$(clasp_swarm_completion_key "$task_file")"

    if clasp_swarm_completion_marker_exists "$completed_root" "$task_id"; then
      continue
    fi

    if clasp_swarm_completion_marker_exists "$global_completed_root" "$task_id"; then
      continue
    fi

    if [[ -f "$blocked_root/$task_id.json" ]]; then
      printf '__BLOCKED__:%s\n' "$task_file"
      return 0
    fi

    if clasp_swarm_task_dependencies_met "$task_file" "$global_completed_root"; then
      printf '%s\n' "$task_file"
      return 0
    fi

    if [[ -z "$first_pending" ]]; then
      first_pending="$task_file"
    fi
  done < <(clasp_swarm_task_files "$lane_dir")

  if [[ -n "$first_pending" ]]; then
    printf '__WAIT__:%s\n' "$first_pending"
    return 0
  fi

  return 1
}

clasp_swarm_git_is_clean() {
  local repo_root="$1"

  git -C "$repo_root" diff --quiet --ignore-submodules --exit-code &&
    git -C "$repo_root" diff --cached --quiet --ignore-submodules --exit-code &&
    [[ -z "$(git -C "$repo_root" ls-files --others --exclude-standard)" ]]
}

clasp_swarm_current_branch() {
  local repo_root="$1"

  git -C "$repo_root" branch --show-current
}

clasp_swarm_reconcile_main_and_trunk() {
  local repo_root="$1"
  local main_branch="$2"
  local trunk_branch="$3"
  local main_head=""
  local trunk_head=""
  local current_branch=""

  if ! git -C "$repo_root" show-ref --verify --quiet "refs/heads/$main_branch"; then
    echo "missing main branch: $main_branch" >&2
    return 1
  fi

  if ! git -C "$repo_root" show-ref --verify --quiet "refs/heads/$trunk_branch"; then
    echo "missing trunk branch: $trunk_branch" >&2
    return 1
  fi

  main_head="$(git -C "$repo_root" rev-parse "$main_branch")"
  trunk_head="$(git -C "$repo_root" rev-parse "$trunk_branch")"

  if [[ "$main_head" == "$trunk_head" ]]; then
    printf '%s\n' "$main_head"
    return 0
  fi

  if git -C "$repo_root" merge-base --is-ancestor "$trunk_head" "$main_head"; then
    git -C "$repo_root" update-ref "refs/heads/$trunk_branch" "$main_head" "$trunk_head"
    printf '%s\n' "$main_head"
    return 0
  fi

  if git -C "$repo_root" merge-base --is-ancestor "$main_head" "$trunk_head"; then
    current_branch="$(clasp_swarm_current_branch "$repo_root")"
    if [[ "$current_branch" != "$main_branch" ]]; then
      echo "cannot fast-forward $main_branch from $trunk_branch while checked out on $current_branch" >&2
      return 1
    fi

    if ! clasp_swarm_git_is_clean "$repo_root"; then
      echo "cannot fast-forward $main_branch from $trunk_branch with a dirty worktree" >&2
      return 1
    fi

    git -C "$repo_root" merge --ff-only "$trunk_branch" >/dev/null
    printf '%s\n' "$(git -C "$repo_root" rev-parse "$main_branch")"
    return 0
  fi

  echo "$main_branch and $trunk_branch have diverged; reconcile them manually before continuing" >&2
  return 1
}
