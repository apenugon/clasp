# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `node test/secret-handling.test.mjs` fails in a way that clearly points to a benchmark harness bug.
- Use the local files as the source of truth.
- Keep the solution minimal. The intended fix is in `src/main.mjs`.

Relevant files:

- `src/main.mjs`: handwritten secret-handling helpers and demo
- `test/secret-handling.test.mjs`: exact required behavior

Preferred workflow:

1. Read `test/secret-handling.test.mjs`.
2. Update `src/main.mjs`.
3. Run `node test/secret-handling.test.mjs`.
