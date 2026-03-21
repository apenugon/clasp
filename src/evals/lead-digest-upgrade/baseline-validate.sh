#!/usr/bin/env bash
set -euo pipefail

eval_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$eval_root/../../../.." && pwd)"
candidate_arg="${1:-}"

if [[ -z "$candidate_arg" ]]; then
  echo "usage: bash $eval_root/baseline-validate.sh <candidate-dir>" >&2
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

output_root="$(mktemp -d "${TMPDIR:-/tmp}/clasp-eval-lead-digest-baseline.XXXXXX")"
compiled_path="$output_root/candidate.js"

cleanup() {
  rm -rf "$output_root"
}
trap cleanup EXIT

"$claspc" check "$entry_path" --compiler=bootstrap >/dev/null
"$claspc" compile "$entry_path" -o "$compiled_path" --compiler=bootstrap >/dev/null

node "$eval_root/baseline-validate.mjs" "$candidate_dir" "$compiled_path"
