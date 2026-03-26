# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `node test/interop-boundary.test.mjs` fails in a way that clearly points to a benchmark harness bug.
- Use the local files as the source of truth. Do not inspect the parent project just to learn the task shape.
- Keep the solution minimal. The intended fix is in `src/main.mjs`.

Relevant files:

- `src/main.mjs`: handwritten JavaScript refinement and blame reporting
- `support/inspectLead.mjs`: foreign helper fixture
- `test/interop-boundary.test.mjs`: exact required behavior

Preferred workflow:

1. Read `test/interop-boundary.test.mjs`.
2. Update `src/main.mjs`.
3. Run `node test/interop-boundary.test.mjs`.
