# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless the local verifier points to a broader runtime problem.
- Use the local files as the source of truth. Do not inspect the parent project just to learn the task shape.
- Keep the solution minimal and local. The intended fix is in `src/main.mjs`.

Relevant files:

- `src/main.mjs`: protected access helpers and proof metadata
- `test/authorization-data-access.test.mjs`: exact required behavior

Preferred workflow:

1. Read `test/authorization-data-access.test.mjs`.
2. Update `src/main.mjs`.
3. Run `node test/authorization-data-access.test.mjs`.
