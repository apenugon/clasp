# Task: Repair Handwritten Host Glue For Python Worker And Service Interop

This benchmark mirrors the Clasp Python interop task with explicit JavaScript process glue.

## Working Guidance

- This task is intentionally local to this workspace.
- Start with `src/main.mjs`, then read `test/python-interop.test.mjs`.
- Keep the solution explicit. The intended fix is in the handwritten JavaScript host glue, not in the Python fixtures or the test.

## Requirements

- Spawn the worker Python module and service Python package directly from JavaScript.
- Exchange newline-delimited JSON messages with each process.
- Validate requests so invalid budgets fail with `budget must be an integer`.
- Return the same behavior as the mirrored Clasp task.

## Acceptance

The task is complete when `node test/python-interop.test.mjs` passes.
