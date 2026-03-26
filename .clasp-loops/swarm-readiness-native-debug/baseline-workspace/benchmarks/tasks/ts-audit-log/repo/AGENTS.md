# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `node test/audit-log.test.mjs` fails in a way that clearly points to a benchmark harness bug.
- Use the local files as the source of truth.
- Keep the solution minimal. The intended fix is in `src/main.mjs`.

Relevant files:

- `src/main.mjs`: handwritten audit-log helpers and demo
- `test/audit-log.test.mjs`: exact required behavior

Preferred workflow:

1. Read `test/audit-log.test.mjs`.
2. Update `src/main.mjs`.
3. Run `node test/audit-log.test.mjs`.
