# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `bash scripts/verify.sh` fails in a way that clearly points to a compiler/runtime bug.
- Use the local files as the source of truth. Do not inspect the parent project just to learn the task shape.
- Keep the solution minimal. The intended fix is in `Main.clasp`, not in the test.

Relevant files:

- `Main.clasp`: workflow declaration and constraint predicates
- `demo.mjs`: runtime scenario driver
- `test/workflow-correctness.test.mjs`: exact required behavior
- `scripts/verify.sh`: acceptance command

Preferred workflow:

1. Read `test/workflow-correctness.test.mjs`.
2. Update `Main.clasp`.
3. Run `bash scripts/verify.sh`.
