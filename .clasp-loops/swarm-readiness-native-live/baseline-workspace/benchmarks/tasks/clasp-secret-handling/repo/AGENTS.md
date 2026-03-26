# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `bash scripts/verify.sh` fails in a way that clearly points to a compiler/runtime bug.
- Use the local files as the source of truth. Do not inspect the parent project just to learn the task shape.
- Keep the solution minimal and declarative. The intended fix is in `Main.clasp`.

Relevant files:

- `Main.clasp`: prompt, guide, policy, role, agent, tool server, and tool declarations
- `test/secret-handling.test.mjs`: exact required behavior
- `demo.mjs`: end-to-end secret-handling exercise used by the test
- `scripts/verify.sh`: acceptance command

Preferred workflow:

1. Read `test/secret-handling.test.mjs`.
2. Update `Main.clasp`.
3. Run `bash scripts/verify.sh`.
