# Task: Repair Handwritten Unsafe Refinement And Blame Reporting In JavaScript

This benchmark mirrors the Clasp interop-boundary task with explicit JavaScript host glue and handwritten refinement.

## Working Guidance

- This task is intentionally local to this workspace.
- Start with `src/main.mjs`, then read `test/interop-boundary.test.mjs`.
- Keep the solution explicit. The intended fix is in the handwritten JavaScript refinement path, not in the support module or test.

## Requirements

- Call the existing local TypeScript-style helper directly from JavaScript.
- Refine the foreign result into the expected nested shape before exposing it.
- Return the same behavior as the mirrored Clasp task, including this exact blame string:
  `foreign inspectLead via ./support/inspectLead.d.ts failed: accepted must be a boolean`
- Do not change the support fixture or the test expectations.

## Acceptance

The task is complete when `node test/interop-boundary.test.mjs` passes.
