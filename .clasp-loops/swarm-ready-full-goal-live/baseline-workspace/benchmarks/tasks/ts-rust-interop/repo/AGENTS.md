# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `node test/rust-interop.test.mjs` fails in a way that clearly points to a benchmark harness bug.
- Use the local files as the source of truth. Do not inspect the parent project just to learn the task shape.
- Keep the solution minimal. The intended fix is in `src/nativeInterop.mjs`.

Relevant files:

- `src/nativeInterop.mjs`: handwritten native interop metadata
- `test/rust-interop.test.mjs`: exact required behavior

Preferred workflow:

1. Read `test/rust-interop.test.mjs`.
2. Update `src/nativeInterop.mjs`.
3. Run `node test/rust-interop.test.mjs`.
