#!/usr/bin/env bash
set -euo pipefail

run_case() {
  cabal test clasp-compiler-test --test-show-details=direct --test-options="-p \"$1\" --hide-successes --color never"
}

run_case "hosted verify scripts avoid Haskell and Node in the promoted native self-check loop"
run_case "primary compiler driver avoids the Node hosted tool runner in the live execution path"
run_case "renderHostedPrimaryEntrySource flattens the hosted compiler entrypoint for self-hosted verification"
run_case "hosted native tool runner compiles compiler-entrypoint-shaped sources without a bootstrap oracle"
run_case "promoted hosted native seed rebuilds end-to-end without JS staging"
run_case "compiled hosted compiler accepts multiline continuation formatting"
run_case "compiled hosted compiler accepts trailing commas in structured literals"
run_case "compiled hosted compiler handles block expressions and block-local declarations end to end"
run_case "compiled hosted compiler handles mutable block assignments end to end"
run_case "compiled hosted compiler handles for-loops over list and string values end to end"
run_case "compiled hosted compiler handles early returns end to end"
run_case "compiled hosted compiler handles if expressions end to end"
run_case "compiled hosted compiler handles equality and integer comparisons end to end"
run_case "claspc compile prefers the hosted Clasp compiler for the hosted compiler entrypoint"
run_case "claspc native prefers the hosted Clasp compiler for the hosted compiler entrypoint"
