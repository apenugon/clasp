#!/usr/bin/env bash
set -euo pipefail

project_root="${CLASP_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
tmp_root="$(mktemp -d)"
compiled_path="$tmp_root/browser-counter.mjs"
artifact_path="$tmp_root/index.html"
claspc_bin="$(
  env -u CLASP_CLASPC -u CLASPC_BIN CLASP_PROJECT_ROOT="$project_root" \
    "$project_root/scripts/resolve-claspc.sh"
)"

cleanup() {
  rm -rf "$tmp_root"
}

trap cleanup EXIT

run_verify() {
  cd "$project_root"
  timeout 60 "$claspc_bin" --json check examples/browser-counter/Main.clasp | grep -F '"status":"ok"' >/dev/null
  timeout 60 "$claspc_bin" compile examples/browser-counter/Main.clasp -o "$compiled_path" >/dev/null
  timeout 30 node --check examples/browser-counter/build-app.mjs
  proof_json="$(timeout 30 node examples/browser-counter/build-app.mjs "$compiled_path" "$artifact_path")"
  printf '%s\n' "$proof_json" | grep -F '"status":"ok"' >/dev/null
  printf '%s\n' "$proof_json" | grep -F '"title":"Clasp browser counter"' >/dev/null
  printf '%s\n' "$proof_json" | grep -F '"initialCount":"0"' >/dev/null
  printf '%s\n' "$proof_json" | grep -F '"afterTwoClicks":"2"' >/dev/null
  grep -F '<button id="increment" type="button">Add one</button>' "$artifact_path" >/dev/null
  grep -F 'increment.addEventListener("click"' "$artifact_path" >/dev/null
  printf '%s\n' '{"status":"ok","implementation":"clasp-frontend-js","example":"browser-counter","artifact":"index.html"}'
}

if [[ -n "${IN_NIX_SHELL:-}" || -n "${CLASP_CLASPC:-}" ]]; then
  run_verify
else
  nix develop "$project_root" --command bash -lc "
    set -euo pipefail
    export CLASP_PROJECT_ROOT=\"$project_root\"
    bash examples/browser-counter/scripts/verify.sh
  "
fi
