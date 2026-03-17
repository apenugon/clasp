#!/usr/bin/env bash
set -euo pipefail

clasp_prepare_isolated_codex_home() {
  if [[ $# -ne 2 ]]; then
    echo "usage: clasp_prepare_isolated_codex_home <seed-codex-home> <isolated-codex-home>" >&2
    return 1
  fi

  local seed_home="$1"
  local isolated_home="$2"
  local seed_files=(
    auth.json
    config.json
    config.toml
    version.json
    update-check.json
    .personality_migration
    instructions.md
  )
  local seed_file=""

  rm -rf "$isolated_home"
  mkdir -p \
    "$isolated_home/log" \
    "$isolated_home/memories" \
    "$isolated_home/sessions" \
    "$isolated_home/shell_snapshots" \
    "$isolated_home/tmp"

  if [[ -d "$seed_home" ]]; then
    for seed_file in "${seed_files[@]}"; do
      if [[ -e "$seed_home/$seed_file" ]]; then
        cp -a "$seed_home/$seed_file" "$isolated_home/$seed_file"
      fi
    done

    if [[ -d "$seed_home/skills" ]]; then
      ln -s "$seed_home/skills" "$isolated_home/skills"
    fi
  fi
}

clasp_prepare_isolated_runtime_home() {
  if [[ $# -ne 1 ]]; then
    echo "usage: clasp_prepare_isolated_runtime_home <runtime-home>" >&2
    return 1
  fi

  local runtime_home="$1"

  rm -rf "$runtime_home"
  mkdir -p \
    "$runtime_home/.cache" \
    "$runtime_home/.config" \
    "$runtime_home/.local/share" \
    "$runtime_home/.local/state" \
    "$runtime_home/tmp"
}
