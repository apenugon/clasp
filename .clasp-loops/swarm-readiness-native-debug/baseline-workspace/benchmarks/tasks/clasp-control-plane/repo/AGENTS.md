# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `bash scripts/verify.sh` fails in a way that clearly points to a compiler/runtime bug.
- Use the local files as the source of truth. Do not inspect the parent project just to learn the task shape.
- Keep the solution minimal and declarative. The intended fix is in `Main.clasp`.

Relevant files:

- `Main.clasp`: repo guide, policy, role, agent, hook, tool, verifier, and merge gate declarations
- `test/control-plane.test.mjs`: exact required behavior
- `demo.mjs`: end-to-end control-plane exercise used by the test
- `scripts/verify.sh`: acceptance command

Preferred workflow:

1. Read `test/control-plane.test.mjs`.
2. Update `Main.clasp`.
3. Run `bash scripts/verify.sh`.
