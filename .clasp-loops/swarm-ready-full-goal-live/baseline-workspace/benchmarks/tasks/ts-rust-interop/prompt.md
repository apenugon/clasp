# Task: Repair Handwritten Host Glue For Rust Native Interop Planning

This benchmark mirrors the Clasp native interop task with explicit JavaScript host glue.

## Working Guidance

- This task is intentionally local to this workspace.
- Start with `src/nativeInterop.mjs`, then read `test/rust-interop.test.mjs`.
- Keep the solution explicit. The intended fix is in the handwritten native interop metadata, not in the test.

## Requirements

- Return one native interop binding for `mockLeadSummaryModel`.
- Build the same Rust metadata and cargo command as the mirrored Clasp task.
- Keep the shape readable and deterministic.

## Acceptance

The task is complete when `node test/rust-interop.test.mjs` passes.
