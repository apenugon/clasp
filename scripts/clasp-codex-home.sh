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

clasp_codex_log_has_retryable_tool_model_error() {
  if [[ $# -lt 1 ]]; then
    echo "usage: clasp_codex_log_has_retryable_tool_model_error <log-file> [log-file...]" >&2
    return 1
  fi

  local log_file=""
  for log_file in "$@"; do
    [[ -f "$log_file" ]] || continue
    if LC_ALL=C grep -F --quiet 'image_generation_user_error' "$log_file" \
      && LC_ALL=C grep -F --quiet 'gpt-image-2' "$log_file" \
      && LC_ALL=C grep -F --quiet 'invalid_value' "$log_file"; then
      return 0
    fi
  done

  return 1
}

clasp_codex_clear_retryable_tool_state() {
  if [[ $# -ne 1 ]]; then
    echo "usage: clasp_codex_clear_retryable_tool_state <isolated-codex-home>" >&2
    return 1
  fi

  local isolated_home="$1"

  rm -f "$isolated_home/models_cache.json"
  rm -rf "$isolated_home/tmp"
  mkdir -p "$isolated_home/tmp"
}

clasp_codex_exec_with_tool_model_retry() {
  if [[ $# -lt 6 ]]; then
    echo "usage: clasp_codex_exec_with_tool_model_retry <role> <isolated-codex-home> <report-json> <log-jsonl> <prompt-file> <command...>" >&2
    return 1
  fi

  local role="$1"
  local isolated_home="$2"
  local report_json="$3"
  local log_jsonl="$4"
  local prompt_file="$5"
  shift 5

  local stderr_log="${log_jsonl}.stderr"
  local first_status=0
  local retry_status=0
  local -a command=("$@")
  local -a retry_command=("$@" --ignore-user-config)

  rm -f "$report_json" "$stderr_log"
  if "${command[@]}" < "$prompt_file" > "$log_jsonl" 2> "$stderr_log"; then
    return 0
  fi
  first_status="$?"

  if ! clasp_codex_log_has_retryable_tool_model_error "$log_jsonl" "$stderr_log"; then
    return "$first_status"
  fi

  clasp_codex_clear_retryable_tool_state "$isolated_home"
  rm -f "$report_json"
  printf '{"type":"clasp.codex.retry","role":"%s","reason":"invalid-image-tool-model","first_exit_status":%s,"action":"clear-isolated-tool-state-and-ignore-user-config"}\n' \
    "$role" "$first_status" >> "$log_jsonl"

  if "${retry_command[@]}" < "$prompt_file" >> "$log_jsonl" 2>> "$stderr_log"; then
    return 0
  fi
  retry_status="$?"
  return "$retry_status"
}
