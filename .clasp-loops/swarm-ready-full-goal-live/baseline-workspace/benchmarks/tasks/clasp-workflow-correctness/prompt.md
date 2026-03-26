# Task: Restore Workflow Invariants And Transition Guards

The repository models one small workflow-correctness benchmark in `Clasp`.

The current `CounterFlow` benchmark still compiles, but it no longer enforces the invariant and transition guards that the runtime scenario expects. Repair the workflow definition so valid transitions still succeed while invalid starts and deliveries fail with the declared constraint names.

## Working Guidance

- This task is intentionally local to the workspace.
- Start with `test/workflow-correctness.test.mjs` and `Main.clasp`.
- Do not inspect the parent repo unless `bash scripts/verify.sh` exposes a compiler/runtime bug rather than a task-repo bug.
- Keep the fix in `Main.clasp`. Do not patch the test or the demo to relax the scenario.

## Requirements

- Keep `Counter` as the workflow state record.
- Preserve the existing helper predicates and wire them into the workflow declaration.
- Valid deliveries must still succeed and return the incremented count.
- Starting with a negative count must fail the workflow invariant.
- Delivering from the limit state must fail the precondition.
- Delivering past the limit must fail the postcondition.

## Constraints

- Keep the codebase small and readable.
- Preserve the current runtime import and compiled-module loading flow.
- Do not bypass the worker runtime contract with handwritten fake results.

## Acceptance

The task is complete when `bash scripts/verify.sh` passes.
