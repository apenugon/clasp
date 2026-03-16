#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nix_config_features='experimental-features = nix-command flakes'
readonly_nix_cache_root="/tmp/clasp-nix-cache"
full_verify_commands=$'
bash scripts/test-verify-all.sh
bash scripts/test-swarm-control.sh
cabal test
cabal run claspc -- check compiler/hosted/Main.clasp
bash compiler/hosted/scripts/verify.sh
bash examples/lead-app-ts/scripts/verify.sh
node benchmarks/run-benchmark.mjs list >/dev/null
bash benchmarks/test-task-prep.sh
bash benchmarks/test-persistence-benchmarks.sh
bash benchmarks/test-correctness-benchmarks.sh
bash benchmarks/test-external-adaptation.sh
bash benchmarks/test-foreign-interop.sh
bash benchmarks/test-interop-boundary.sh
bash benchmarks/test-secret-handling.sh
bash benchmarks/test-authorization-data-access.sh
bash benchmarks/test-audit-log.sh
bash benchmarks/test-boundary-transport-benchmarks.sh
bash benchmarks/test-backend-benchmarks.sh
bash benchmarks/test-series-summary.sh
'
fallback_verify_commands=$'
bash scripts/test-verify-all.sh
bash scripts/test-task-manifest.sh
'

if [[ -n "${NIX_CONFIG:-}" ]]; then
  export NIX_CONFIG="${NIX_CONFIG}"$'\n'"${nix_config_features}"
else
  export NIX_CONFIG="${nix_config_features}"
fi

run_command_block() {
  local commands="$1"
  local command=""

  while IFS= read -r command; do
    [[ -z "$command" ]] && continue
    (
      set -euo pipefail
      cd "$project_root"
      export CLASP_PROJECT_ROOT="$project_root"
      bash -lc "$command"
    )
  done <<< "$commands"
}

if [[ -z "${XDG_CACHE_HOME:-}" || ! -w "${XDG_CACHE_HOME:-/nonexistent}" ]]; then
  export XDG_CACHE_HOME="$readonly_nix_cache_root"
  mkdir -p "$XDG_CACHE_HOME"
fi

nix_failure_log="$(mktemp)"
trap 'rm -f "$nix_failure_log"' EXIT

if nix develop -c bash -lc "
  set -euo pipefail
  cd \"$project_root\"
  export CLASP_PROJECT_ROOT=\"$project_root\"
  ${CLASP_VERIFY_FULL_COMMANDS:-$full_verify_commands}
" 2>"$nix_failure_log"; then
  exit 0
fi

if grep -Eq 'readonly database|daemon-socket/socket' "$nix_failure_log"; then
  printf 'verify-all: falling back to sandbox verification because Nix is unavailable in this environment\n' >&2
  run_command_block "${CLASP_VERIFY_FALLBACK_COMMANDS:-$fallback_verify_commands}"
  exit 0
fi

cat "$nix_failure_log" >&2
exit 1
