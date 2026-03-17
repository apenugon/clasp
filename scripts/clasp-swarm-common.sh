#!/usr/bin/env bash
set -euo pipefail

CLASP_SWARM_GIT_COMPLETION_CACHE_KEY=""
CLASP_SWARM_GIT_COMPLETION_CACHE_FILE=""

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
  local task_file=""

  while IFS= read -r task_file; do
    [[ -n "$task_file" ]] || continue
    clasp_swarm_validate_task_manifest "$task_file" >/dev/null
    printf '%s\n' "$task_file"
  done < <(find "$lane_dir" -maxdepth 1 -type f -name '*.md' | sort)
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

clasp_swarm_git_completion_cache_cleanup() {
  if [[ -n "${CLASP_SWARM_GIT_COMPLETION_CACHE_FILE:-}" ]]; then
    rm -f "$CLASP_SWARM_GIT_COMPLETION_CACHE_FILE"
    CLASP_SWARM_GIT_COMPLETION_CACHE_FILE=""
  fi
}

clasp_swarm_git_completion_cache_file() {
  local repo_root="$1"
  local main_branch="${2:-main}"
  local trunk_branch="${3:-agents/swarm-trunk}"
  local key=""
  local cache_file=""
  local refs=()

  key="${repo_root}"$'\t'"${main_branch}"$'\t'"${trunk_branch}"

  if [[ "${CLASP_SWARM_GIT_COMPLETION_CACHE_KEY:-}" == "$key" ]] && \
     [[ -n "${CLASP_SWARM_GIT_COMPLETION_CACHE_FILE:-}" ]] && \
     [[ -f "${CLASP_SWARM_GIT_COMPLETION_CACHE_FILE}" ]]; then
    printf '%s\n' "$CLASP_SWARM_GIT_COMPLETION_CACHE_FILE"
    return 0
  fi

  clasp_swarm_git_completion_cache_cleanup
  cache_file="$(mktemp)"

  if git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$main_branch"; then
      refs+=("refs/heads/$main_branch")
    fi
    if [[ "$trunk_branch" != "$main_branch" ]] && \
       git -C "$repo_root" show-ref --verify --quiet "refs/heads/$trunk_branch"; then
      refs+=("refs/heads/$trunk_branch")
    fi
    if [[ "${#refs[@]}" -gt 0 ]]; then
      git -C "$repo_root" log --format='%H%x09%cI%x09%s' "${refs[@]}" | \
        awk -F '\t' '
          {
            subject = $3
            while (match(subject, /(^|[^A-Z0-9])([A-Z]{2,3}-[0-9]{3})([^A-Z0-9]|$)/, match_parts)) {
              task_id = match_parts[2]
              if (!(task_id in seen)) {
                print task_id "\t" $1 "\t" $2
                seen[task_id] = 1
              }
              subject = substr(subject, RSTART + RLENGTH)
            }
          }
        ' > "$cache_file"
    else
      : > "$cache_file"
    fi
  else
    : > "$cache_file"
  fi

  CLASP_SWARM_GIT_COMPLETION_CACHE_KEY="$key"
  CLASP_SWARM_GIT_COMPLETION_CACHE_FILE="$cache_file"
  printf '%s\n' "$cache_file"
}

clasp_swarm_git_completion_marker_exists() {
  local repo_root="$1"
  local task_ref="$2"
  local main_branch="${3:-main}"
  local trunk_branch="${4:-agents/swarm-trunk}"
  local key=""
  local cache_file=""

  key="$(clasp_swarm_completion_key "$task_ref")"
  cache_file="$(clasp_swarm_git_completion_cache_file "$repo_root" "$main_branch" "$trunk_branch")"

  [[ -f "$cache_file" ]] && awk -F '\t' -v key="$key" '$1 == key { found = 1; exit } END { exit(found ? 0 : 1) }' "$cache_file"
}

clasp_swarm_git_completion_field() {
  local repo_root="$1"
  local task_ref="$2"
  local field_index="$3"
  local main_branch="${4:-main}"
  local trunk_branch="${5:-agents/swarm-trunk}"
  local key=""
  local cache_file=""

  key="$(clasp_swarm_completion_key "$task_ref")"
  cache_file="$(clasp_swarm_git_completion_cache_file "$repo_root" "$main_branch" "$trunk_branch")"

  awk -F '\t' -v key="$key" -v idx="$field_index" '$1 == key { print $idx; exit }' "$cache_file"
}

clasp_swarm_git_completion_commit() {
  clasp_swarm_git_completion_field "$1" "$2" 2 "${3:-main}" "${4:-agents/swarm-trunk}"
}

clasp_swarm_git_completion_stamp() {
  clasp_swarm_git_completion_field "$1" "$2" 3 "${3:-main}" "${4:-agents/swarm-trunk}"
}

clasp_swarm_task_is_completed() {
  local markers_dir="$1"
  local task_ref="$2"
  local repo_root="${3:-$(clasp_swarm_project_root)}"
  local main_branch="${4:-main}"
  local trunk_branch="${5:-agents/swarm-trunk}"

  if clasp_swarm_completion_marker_exists "$markers_dir" "$task_ref"; then
    return 0
  fi

  clasp_swarm_git_completion_marker_exists "$repo_root" "$task_ref" "$main_branch" "$trunk_branch"
}

clasp_swarm_reconcile_completion_dir_with_git() {
  local markers_dir="$1"
  local repo_root="${2:-$(clasp_swarm_project_root)}"
  local main_branch="${3:-main}"
  local trunk_branch="${4:-agents/swarm-trunk}"
  local path=""
  local base=""
  local key=""
  local git_commit=""
  local git_stamp=""

  mkdir -p "$markers_dir"

  shopt -s nullglob
  for path in "$markers_dir"/*; do
    [[ -f "$path" ]] || continue
    base="$(basename "$path")"
    key="$(clasp_swarm_completion_key "$base")"
    git_commit="$(clasp_swarm_git_completion_commit "$repo_root" "$key" "$main_branch" "$trunk_branch" || true)"
    git_stamp="$(clasp_swarm_git_completion_stamp "$repo_root" "$key" "$main_branch" "$trunk_branch" || true)"

    if [[ -n "$git_commit" && -n "$git_stamp" ]]; then
      printf '%s\t%s\n' "$git_stamp" "$git_commit" > "$markers_dir/$key"
      continue
    fi

    rm -f "$path"
  done
  shopt -u nullglob
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

clasp_swarm_prompt_max_bytes() {
  printf '%s\n' "${CLASP_SWARM_PROMPT_MAX_BYTES:-262144}"
}

clasp_swarm_prompt_size_bytes() {
  local prompt_file="$1"
  wc -c < "$prompt_file" | tr -d '[:space:]'
}

clasp_swarm_assert_prompt_size() {
  local prompt_file="$1"
  local label="$2"
  local size_bytes=""
  local limit_bytes=""

  size_bytes="$(clasp_swarm_prompt_size_bytes "$prompt_file")"
  limit_bytes="$(clasp_swarm_prompt_max_bytes)"

  if [[ ! "$limit_bytes" =~ ^[0-9]+$ ]] || (( limit_bytes <= 0 )); then
    echo "CLASP_SWARM_PROMPT_MAX_BYTES must be a positive integer" >&2
    return 1
  fi

  if (( size_bytes > limit_bytes )); then
    printf '%s\n' \
      "$label prompt is ${size_bytes} bytes, which exceeds CLASP_SWARM_PROMPT_MAX_BYTES=${limit_bytes}" >&2
    return 1
  fi
}

clasp_swarm_spawn_detached() {
  local log_file="$1"
  shift
  local python3_bin=""

  # Prefer python3 so we can return the real child pid on macOS.
  if [[ -x /usr/bin/python3 ]]; then
    python3_bin="/usr/bin/python3"
  elif command -v python3 >/dev/null 2>&1; then
    python3_bin="$(command -v python3)"
  fi

  if [[ -n "$python3_bin" ]]; then
    "$python3_bin" - "$log_file" "$@" <<'PY'
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
  elif command -v setsid >/dev/null 2>&1; then
    setsid "$@" >"$log_file" 2>&1 < /dev/null &
  elif command -v nohup >/dev/null 2>&1; then
    nohup "$@" >"$log_file" 2>&1 < /dev/null &
  else
    "$@" >"$log_file" 2>&1 < /dev/null &
  fi

  printf '%s\n' "$!"
}

clasp_swarm_task_dependencies() {
  local task_file="$1"

  node "$(clasp_swarm_project_root)/scripts/clasp-swarm-validate-task.mjs" --print-field dependencies "$task_file"
}

clasp_swarm_task_batch_label() {
  local task_file="$1"

  node "$(clasp_swarm_project_root)/scripts/clasp-swarm-validate-task.mjs" --print-field batchLabel "$task_file"
}

clasp_swarm_task_dependency_labels() {
  local task_file="$1"

  node "$(clasp_swarm_project_root)/scripts/clasp-swarm-validate-task.mjs" --print-field dependencyLabels "$task_file"
}

clasp_swarm_validate_task_manifest() {
  local task_file="$1"

  node "$(clasp_swarm_project_root)/scripts/clasp-swarm-validate-task.mjs" "$task_file"
}

clasp_swarm_batch_is_complete() {
  local batch_label="$1"
  local lane_dir="$2"
  local completed_root="$3"
  local wave_dir=""
  local scan_lane=""
  local task_file=""
  local task_batch=""
  local found=0
  local project_root=""
  local main_branch="${CLASP_SWARM_MAIN_BRANCH:-main}"
  local trunk_branch="${CLASP_SWARM_TRUNK_BRANCH:-agents/swarm-trunk}"
  local scan_lanes=()

  [[ -n "$batch_label" ]] || return 1

  project_root="$(clasp_swarm_project_root)"
  if [[ "$lane_dir" == "$project_root"/agents/swarm/*/* ]]; then
    wave_dir="$(dirname "$lane_dir")"
    while IFS= read -r scan_lane; do
      [[ -n "$scan_lane" ]] || continue
      scan_lanes+=("$scan_lane")
    done < <(find "$wave_dir" -mindepth 1 -maxdepth 1 -type d | sort)
  else
    scan_lanes=("$lane_dir")
  fi

  for scan_lane in "${scan_lanes[@]}"; do
    while IFS= read -r task_file; do
      task_batch="$(clasp_swarm_task_batch_label "$task_file")"
      if [[ "$task_batch" != "$batch_label" ]]; then
        continue
      fi

      found=1
      if ! clasp_swarm_task_is_completed "$completed_root" "$task_file" "$project_root" "$main_branch" "$trunk_branch"; then
        return 1
      fi
    done < <(clasp_swarm_task_files "$scan_lane")
  done

  [[ "$found" == "1" ]]
}

clasp_swarm_task_dependencies_met() {
  local task_file="$1"
  local lane_dir="$2"
  local completed_root="$3"
  local dep=""
  local dependency_label=""
  local project_root=""
  local main_branch="${CLASP_SWARM_MAIN_BRANCH:-main}"
  local trunk_branch="${CLASP_SWARM_TRUNK_BRANCH:-agents/swarm-trunk}"

  project_root="$(clasp_swarm_project_root)"

  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    if ! clasp_swarm_task_is_completed "$completed_root" "$dep" "$project_root" "$main_branch" "$trunk_branch"; then
      return 1
    fi
  done < <(clasp_swarm_task_dependencies "$task_file")

  while IFS= read -r dependency_label; do
    [[ -z "$dependency_label" ]] && continue
    if ! clasp_swarm_batch_is_complete "$dependency_label" "$lane_dir" "$completed_root"; then
      return 1
    fi
  done < <(clasp_swarm_task_dependency_labels "$task_file")

  return 0
}

clasp_swarm_select_next_ready_task() {
  local lane_dir="$1"
  local completed_root="$2"
  local global_completed_root="$3"
  local blocked_root="$4"
  local batch_filter="${5:-}"
  local task_file=""
  local task_id=""
  local first_pending=""
  local task_batch=""
  local project_root=""
  local main_branch="${CLASP_SWARM_MAIN_BRANCH:-main}"
  local trunk_branch="${CLASP_SWARM_TRUNK_BRANCH:-agents/swarm-trunk}"

  project_root="$(clasp_swarm_project_root)"

  while IFS= read -r task_file; do
    if [[ -n "$batch_filter" ]]; then
      task_batch="$(clasp_swarm_task_batch_label "$task_file")"
      if [[ "$task_batch" != "$batch_filter" ]]; then
        continue
      fi
    fi

    task_id="$(clasp_swarm_completion_key "$task_file")"

    if clasp_swarm_task_is_completed "$completed_root" "$task_id" "$project_root" "$main_branch" "$trunk_branch"; then
      continue
    fi

    if clasp_swarm_task_is_completed "$global_completed_root" "$task_id" "$project_root" "$main_branch" "$trunk_branch"; then
      continue
    fi

    if [[ -f "$blocked_root/$task_id.json" ]]; then
      printf '__BLOCKED__:%s\n' "$task_file"
      return 0
    fi

    if clasp_swarm_task_dependencies_met "$task_file" "$lane_dir" "$global_completed_root"; then
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
