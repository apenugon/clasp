#!/usr/bin/env bash
set -euo pipefail

suite_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$suite_root/../../../.." && pwd)"
task_id="${1:-}"
candidate_arg="${2:-}"

if [[ -z "$task_id" || -z "$candidate_arg" ]]; then
  echo "usage: bash $suite_root/validate.sh <task-id> <candidate-dir>" >&2
  exit 2
fi

candidate_dir="$(cd "$(dirname "$candidate_arg")" && pwd)/$(basename "$candidate_arg")"
entry_path="$candidate_dir/Main.clasp"

if [[ ! -f "$entry_path" ]]; then
  echo "candidate entrypoint not found: $entry_path" >&2
  exit 1
fi

if [[ -n "${CLASP_CLASPC:-}" ]]; then
  claspc="$CLASP_CLASPC"
elif [[ -x "$repo_root/dist-newstyle/build/x86_64-linux/ghc-9.8.4/clasp-compiler-0.1.0.0/x/claspc/build/claspc/claspc" ]]; then
  claspc="$repo_root/dist-newstyle/build/x86_64-linux/ghc-9.8.4/clasp-compiler-0.1.0.0/x/claspc/build/claspc/claspc"
else
  claspc="$(find "$repo_root/dist-newstyle" -type f -name claspc | head -n 1)"
fi

if [[ -z "${claspc:-}" || ! -x "$claspc" ]]; then
  echo "could not locate an executable claspc binary under dist-newstyle" >&2
  exit 1
fi

output_root="$(mktemp -d "${TMPDIR:-/tmp}/clasp-contract-suite.XXXXXX")"
compiled_path="$output_root/candidate.js"
context_path="$output_root/candidate.context.json"
air_path="$output_root/candidate.air.json"

cleanup() {
  rm -rf "$output_root"
}
trap cleanup EXIT

"$claspc" check "$entry_path" --compiler=bootstrap >/dev/null
"$claspc" compile "$entry_path" -o "$compiled_path" --compiler=bootstrap >/dev/null
"$claspc" context "$entry_path" -o "$context_path" --compiler=bootstrap >/dev/null
"$claspc" air "$entry_path" -o "$air_path" --compiler=bootstrap >/dev/null

node "$suite_root/validate.mjs" "$task_id" "$candidate_dir" "$compiled_path" "$context_path" "$air_path"
