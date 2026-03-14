#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

nix develop -c bash -lc "
  set -euo pipefail
  cd \"$project_root\"
  bash scripts/test-swarm-control.sh
  cabal test
  cabal run claspc -- check examples/hello.clasp --compiler=bootstrap
  cabal run claspc -- check examples/status.clasp --compiler=bootstrap
  cabal run claspc -- check examples/records.clasp --compiler=bootstrap
  cabal run claspc -- check examples/lists.clasp --compiler=bootstrap
  cabal run claspc -- check examples/let.clasp --compiler=bootstrap
  cabal run claspc -- check examples/blocks.clasp --compiler=bootstrap
  cabal run claspc -- check examples/compiler-renderers.clasp --compiler=bootstrap
  cabal run claspc -- check examples/compiler-loader.clasp --compiler=bootstrap
  cabal run claspc -- check examples/compiler-parser.clasp --compiler=bootstrap
  cabal run claspc -- check compiler/hosted/Main.clasp
  cabal run claspc -- check examples/project/Main.clasp --compiler=bootstrap
  cabal run claspc -- check examples/control-plane/Main.clasp --compiler=bootstrap
  cabal run claspc -- check examples/support-agent/Main.clasp --compiler=bootstrap
  cabal run claspc -- check examples/durable-workflow/Main.clasp --compiler=bootstrap
  cabal run claspc -- check examples/durable-workflow/Main.next.clasp --compiler=bootstrap
  bash examples/interop-ts/scripts/verify.sh
  bash compiler/hosted/scripts/verify.sh
  bash examples/prompt-functions/scripts/verify.sh
  bash examples/support-agent/scripts/verify.sh
  bash examples/lead-app/scripts/verify.sh
  bash examples/support-console/scripts/verify.sh
  bash examples/release-gate/scripts/verify.sh
  cabal run claspc -- check examples/lead-app/Main.clasp --compiler=bootstrap
  cabal run claspc -- check examples/support-console/Main.clasp --compiler=bootstrap
  cabal run claspc -- check examples/release-gate/Main.clasp --compiler=bootstrap
  mkdir -p dist/control-plane
  cabal run claspc -- compile examples/control-plane/Main.clasp -o dist/control-plane/Main.js --compiler=bootstrap
  node examples/control-plane/demo.mjs dist/control-plane/Main.js >/dev/null
  mkdir -p dist/durable-workflow
  cabal run claspc -- compile examples/durable-workflow/Main.clasp -o dist/durable-workflow/Main.js --compiler=bootstrap
  cabal run claspc -- compile examples/durable-workflow/Main.next.clasp -o dist/durable-workflow/Main.next.js --compiler=bootstrap
  node examples/durable-workflow/demo.mjs dist/durable-workflow/Main.js dist/durable-workflow/Main.next.js >/dev/null
  export CLASP_PROJECT_ROOT=\"$project_root\"
  bash examples/lead-app-ts/scripts/verify.sh
  node benchmarks/run-benchmark.mjs list >/dev/null
  bash benchmarks/test-task-prep.sh
  bash benchmarks/test-external-adaptation.sh
  bash benchmarks/test-foreign-interop.sh
  bash benchmarks/test-interop-boundary.sh
  bash benchmarks/test-secret-handling.sh
  bash benchmarks/test-backend-benchmarks.sh
  bash benchmarks/test-series-summary.sh
"
