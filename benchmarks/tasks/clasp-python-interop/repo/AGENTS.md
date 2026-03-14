# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `bash scripts/verify.sh` fails in a way that clearly points to a compiler/runtime bug.
- Use the local files as the source of truth. Do not inspect the parent project just to learn the task shape.
- Keep the solution minimal and declarative. The intended fix is in `Main.clasp`.

Relevant files:

- `Main.clasp`: typed hook and route declarations
- `clasp_worker_bridge.py`: worker-side Python implementation
- `clasp_service_pkg/__main__.py`: service-side Python implementation
- `demo.mjs`: end-to-end runtime exercise

Preferred workflow:

1. Read `Main.clasp`.
2. Run `bash scripts/verify.sh`.
3. Add the missing typed Python interop declarations.
