#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

nix develop -c bash -lc "
  set -euo pipefail
  cd \"$project_root\"
  bash scripts/test-swarm-control.sh
  cabal test
  cabal run claspc -- check examples/hello.clasp
  cabal run claspc -- check examples/status.clasp
  cabal run claspc -- check examples/records.clasp
  cabal run claspc -- check examples/lead-app/Main.clasp
  export CLASP_PROJECT_ROOT=\"$project_root\"
  bash examples/lead-app-ts/scripts/verify.sh
  node benchmarks/run-benchmark.mjs list >/dev/null
"
