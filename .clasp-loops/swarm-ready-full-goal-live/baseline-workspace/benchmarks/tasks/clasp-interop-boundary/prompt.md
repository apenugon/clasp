# Task: Repair Compiler-Managed Unsafe Refinement And Blame Reporting In Clasp

This benchmark measures unsafe-refinement friction and root-cause blame quality at a compiler-managed foreign package boundary.

## Working Guidance

- This task is intentionally local to this workspace.
- Start with `Main.clasp`, then read `demo.mjs` and `scripts/verify.sh`.
- Keep the solution declarative. The intended fix is in the package-backed foreign declaration, not in the JavaScript demo or support module.

## Requirements

- Move the foreign call onto the local compiler-managed TypeScript package import.
- The foreign declaration must explicitly acknowledge the unchecked package return leaf.
- The demo must print this exact JSON:
  `{"packageKind":"typescript","validLabel":"foreign:Acme","validAccepted":true,"invalid":"foreign inspectLead via ./support/inspectLead.d.ts failed: accepted must be a boolean"}`
- Do not replace the package-backed foreign call with handwritten JavaScript validation or host glue.

## Acceptance

The task is complete when `bash scripts/verify.sh` passes.
