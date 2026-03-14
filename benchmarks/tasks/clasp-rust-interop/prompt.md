# Task: Restore Compiler-Managed Rust Native Interop Metadata In Clasp

This benchmark compares compiler-managed Rust native interop metadata against handwritten host glue on the same task.

## Working Guidance

- This task is intentionally local to this workspace.
- Start with `Main.clasp`, then read `demo.mjs` and `scripts/verify.sh`.
- Keep the solution declarative. The intended fix is in the Clasp source, not in the JavaScript runtime harness.

## Requirements

- The compiled module must expose one native interop binding for `mockLeadSummaryModel`.
- The demo must be able to derive the target-aware Rust build plan with:
  - `crateName: "lead_summary_bridge"`
  - `manifestPath: "native/lead-summary/Cargo.toml"`
  - `artifactFileName: "liblead_summary_bridge.so"`
- Do not hard-code the expected output in the demo.

## Acceptance

The task is complete when `bash scripts/verify.sh` passes.
