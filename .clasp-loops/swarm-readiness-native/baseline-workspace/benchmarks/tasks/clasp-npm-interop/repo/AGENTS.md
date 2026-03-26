# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `bash scripts/verify.sh` fails in a way that clearly points to a compiler/runtime bug.
- Use the local files as the source of truth. Do not inspect the parent project just to learn the task shape.
- Keep the solution minimal and declarative. The intended fix is in `Main.clasp`.

Relevant files:

- `Main.clasp`: foreign package declarations and typed entrypoints
- `demo.mjs`: end-to-end interop exercise
- `scripts/verify.sh`: acceptance command

Preferred workflow:

1. Read `Main.clasp`.
2. Run `bash scripts/verify.sh`.
3. Update `Main.clasp` until the compiler-managed package imports work again.
