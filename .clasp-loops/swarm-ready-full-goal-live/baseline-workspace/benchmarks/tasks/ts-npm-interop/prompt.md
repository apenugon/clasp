# Task: Repair Handwritten Host Glue For `npm` And TypeScript Interop

This benchmark mirrors the Clasp package-interop task with explicit JavaScript host glue.

## Working Guidance

- This task is intentionally local to this workspace.
- Start with `src/main.mjs`, then read `test/npm-interop.test.mjs`.
- Keep the solution explicit. The intended fix is in the handwritten host glue, not in the test.

## Requirements

- Import the local `npm` package helper and the local TypeScript-style module helper directly from JavaScript.
- Return the same behavior as the mirrored Clasp task:
  - `packageKinds` must be `["npm", "typescript"]`
  - `upper` must be `"HELLO ADA"`
  - `formatted` must be `"Acme Labs:7"`
- Do not change the test expectations.

## Acceptance

The task is complete when `node test/npm-interop.test.mjs` passes.
