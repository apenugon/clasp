#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workspace_root="${1:?workspace path is required}"
requested_entry="${2:-}"
entry_path=""
check_root=""
context_path=""
air_path=""

resolve_entry_path() {
  if [[ -n "$requested_entry" ]]; then
    printf '%s\n' "$requested_entry"
    return 0
  fi

  if [[ -f "$workspace_root/Main.clasp" ]]; then
    printf '%s/Main.clasp\n' "$workspace_root"
    return 0
  fi

  if [[ -f "$workspace_root/app/Main.clasp" ]]; then
    printf '%s/app/Main.clasp\n' "$workspace_root"
    return 0
  fi

  printf 'unable to resolve Clasp benchmark entrypoint under %s\n' "$workspace_root" >&2
  return 1
}

cleanup() {
  rm -rf "${check_root:-}"
}

trap cleanup EXIT

entry_path="$(resolve_entry_path)"
check_root="$(mktemp -d)"
context_path="$check_root/context.json"
air_path="$check_root/air.json"

run_verify() {
  cd "$project_root"
  claspc check "$entry_path" --compiler=bootstrap >/dev/null
  claspc context "$entry_path" -o "$context_path" --compiler=bootstrap --json >/dev/null
  claspc air "$entry_path" -o "$air_path" --compiler=bootstrap --json >/dev/null
}

if [[ -n "${IN_NIX_SHELL:-}" ]]; then
  run_verify
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash \"$project_root/benchmarks/verify-clasp-backend-check.sh\" \"$workspace_root\" \"$entry_path\"
  "
fi

[[ -f "$context_path" ]]
[[ -f "$air_path" ]]
