# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `npm test` fails in a way that clearly points to the surrounding toolchain instead of the task repo.
- Use the local files as the source of truth.
- Keep the solution minimal. The intended fix is in `src/controlPlane.ts`.

Relevant files:

- `src/controlPlane.ts`: handwritten control-plane declarations and helpers
- `test/control-plane.test.mjs`: exact required behavior
- `package.json`: acceptance command

Preferred workflow:

1. Read `test/control-plane.test.mjs`.
2. Update `src/controlPlane.ts`.
3. Run `npm test`.
