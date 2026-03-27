#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="$project_root/benchmarks/workspaces/foreign-interop-check"
python_shim_root=""

cleanup() {
  if [[ -n "$python_shim_root" ]]; then
    rm -rf "$python_shim_root"
  fi
}

trap cleanup EXIT

rm -rf "$workspace_root"
mkdir -p "$workspace_root"

python3_command() {
  if [[ -x /usr/bin/python3 ]]; then
    printf '%s\n' /usr/bin/python3
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return 0
  fi

  if command -v python >/dev/null 2>&1; then
    printf '%s\n' "$(command -v python)"
    return 0
  fi

  return 1
}

verify_solution() {
  local task_id="$1"
  local workspace="$workspace_root/$task_id"
  local solution_root="$project_root/benchmarks/tasks/$task_id/solution"
  local python_command=""

  node "$project_root/benchmarks/run-benchmark.mjs" prepare "$task_id" --workspace "$workspace" >/dev/null
  cp -R "$solution_root/." "$workspace/"

  if [[ "$task_id" == "ts-python-interop" ]]; then
    if ! python_command="$(python3_command)"; then
      printf 'test-foreign-interop: skipping %s because no python interpreter is available\n' "$task_id" >&2
      return 0
    fi

    if [[ "$(basename "$python_command")" != "python3" ]]; then
      python_shim_root="$(mktemp -d)"
      ln -sf "$python_command" "$python_shim_root/python3"
      export PATH="$python_shim_root:$PATH"
    fi
  fi

  node "$project_root/benchmarks/run-benchmark.mjs" verify "$task_id" \
    --workspace "$workspace" \
    --harness scenario \
    --model deterministic >/dev/null
}

verify_solution "ts-npm-interop"
verify_solution "ts-python-interop"
verify_solution "ts-rust-interop"
