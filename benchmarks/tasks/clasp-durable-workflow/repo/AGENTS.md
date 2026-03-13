# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `bash scripts/verify.sh` fails in a way that clearly points to a compiler/runtime bug.
- Use the local files as the source of truth. Do not inspect the parent project just to learn the task shape.
- Keep the solution minimal. The intended fix is in `demo.mjs`, not in the test.

Relevant files:

- `demo.mjs`: supervised self-update scenario driver
- `test/durable-workflow.test.mjs`: exact required behavior
- `Main.clasp` and `Main.next.clasp`: the paired workflow modules compiled during verification
- `scripts/verify.sh`: acceptance command

Preferred workflow:

1. Read `test/durable-workflow.test.mjs`.
2. Update `demo.mjs`.
3. Run `bash scripts/verify.sh`.
