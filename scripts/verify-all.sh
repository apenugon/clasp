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
  cabal run claspc -- check examples/lists.clasp
  cabal run claspc -- check examples/let.clasp
  cabal run claspc -- check examples/project/Main.clasp
  cabal run claspc -- check examples/control-plane/Main.clasp
  cabal run claspc -- check examples/lead-app/Main.clasp
  cabal run claspc -- check examples/support-console/Main.clasp
  cabal run claspc -- check examples/release-gate/Main.clasp
  mkdir -p dist/control-plane
  cabal run claspc -- compile examples/control-plane/Main.clasp -o dist/control-plane/Main.js
  node examples/control-plane/demo.mjs dist/control-plane/Main.js >/dev/null
  export CLASP_PROJECT_ROOT=\"$project_root\"
  bash examples/lead-app-ts/scripts/verify.sh
  node benchmarks/run-benchmark.mjs list >/dev/null
  bash benchmarks/test-task-prep.sh
  bash benchmarks/test-series-summary.sh
"
