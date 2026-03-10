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
