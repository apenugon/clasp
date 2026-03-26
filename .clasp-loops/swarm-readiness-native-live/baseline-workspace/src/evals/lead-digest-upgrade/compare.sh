#!/usr/bin/env bash
set -euo pipefail

eval_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$eval_root/../../../.." && pwd)"
start_dir="$eval_root/start"
solution_dir="$eval_root/solution"

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

output_root="$(mktemp -d "${TMPDIR:-/tmp}/clasp-eval-lead-digest-compare.XXXXXX")"
compiled_path="$output_root/start.js"
context_path="$output_root/start.context.json"
air_path="$output_root/start.air.json"
baseline_result_path="$output_root/baseline-start.json"
semantic_result_path="$output_root/semantic-start.json"

cleanup() {
  rm -rf "$output_root"
}
trap cleanup EXIT

"$claspc" check "$start_dir/Main.clasp" --compiler=bootstrap >/dev/null
"$claspc" compile "$start_dir/Main.clasp" -o "$compiled_path" --compiler=bootstrap >/dev/null
"$claspc" context "$start_dir/Main.clasp" -o "$context_path" --compiler=bootstrap >/dev/null
"$claspc" air "$start_dir/Main.clasp" -o "$air_path" --compiler=bootstrap >/dev/null

if ! bash "$eval_root/baseline-validate.sh" "$start_dir" >"$baseline_result_path"; then
  :
fi

if ! bash "$eval_root/validate.sh" "$start_dir" >"$semantic_result_path"; then
  :
fi

node "$eval_root/compare.mjs" \
  "$start_dir" \
  "$solution_dir" \
  "$compiled_path" \
  "$context_path" \
  "$air_path" \
  "$baseline_result_path" \
  "$semantic_result_path"
