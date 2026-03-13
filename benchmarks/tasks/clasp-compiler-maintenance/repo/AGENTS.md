# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `bash scripts/verify.sh` fails in a way that clearly points to a compiler/runtime bug.
- Use the local files as the source of truth. Do not inspect the parent project just to learn the task shape.
- Keep the solution minimal. The intended fix is in the copied self-hosted compiler files, not in the test harness.

Relevant files:

- `test/compiler-maintenance.test.mjs`: exact required behavior
- `Main.clasp`: hosted bootstrap snapshot for the self-hosted compiler slice
- `Compiler/Checker.clasp`: tiny checker and inference helpers
- `Compiler/Lower.clasp`: tiny lowering helpers
- `Compiler/Emit/JavaScript.clasp`: tiny JavaScript emitter helpers
- `scripts/verify.sh`: acceptance command

Preferred workflow:

1. Read `test/compiler-maintenance.test.mjs`.
2. Update `Main.clasp` and the relevant files under `Compiler/`.
3. Run `bash scripts/verify.sh`.
