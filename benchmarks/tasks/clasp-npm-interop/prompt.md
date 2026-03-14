# Task: Restore Compiler-Managed `npm` and TypeScript Package Interop In Clasp

This benchmark compares compiler-managed package interop against handwritten host glue on the same small task.

## Working Guidance

- This task is intentionally local to this workspace.
- Start with `Main.clasp`, then read `demo.mjs` and `scripts/verify.sh`.
- Keep the solution declarative. The intended fix is in the foreign package declarations, not in the demo.

## Requirements

- `shout "hello ada"` must resolve through the compiler-managed `npm` package import and produce `"HELLO ADA"`.
- `describe { company = "Acme Labs", budget = 7 }` must resolve through the compiler-managed TypeScript module import and produce `"Acme Labs:7"`.
- The generated binding contract must report both package kinds: `npm` and `typescript`.
- Do not replace the package-backed foreign calls with handwritten JavaScript host bindings.

## Acceptance

The task is complete when `bash scripts/verify.sh` passes.
