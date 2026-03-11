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
