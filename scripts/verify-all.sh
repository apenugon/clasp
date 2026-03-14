#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

nix develop -c bash -lc "
  set -euo pipefail
  cd \"$project_root\"
  bash scripts/test-swarm-control.sh
  cabal test
  cabal run claspc -- check compiler/hosted/Main.clasp
  bash compiler/hosted/scripts/verify.sh
  export CLASP_PROJECT_ROOT=\"$project_root\"
  bash examples/lead-app-ts/scripts/verify.sh
  node benchmarks/run-benchmark.mjs list >/dev/null
  bash benchmarks/test-task-prep.sh
  bash benchmarks/test-persistence-benchmarks.sh
  bash benchmarks/test-external-adaptation.sh
  bash benchmarks/test-foreign-interop.sh
  bash benchmarks/test-interop-boundary.sh
  bash benchmarks/test-secret-handling.sh
  bash benchmarks/test-audit-log.sh
  bash benchmarks/test-backend-benchmarks.sh
  bash benchmarks/test-series-summary.sh
"
