# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `node test/python-interop.test.mjs` fails in a way that clearly points to a benchmark harness bug.
- Use the local files as the source of truth. Do not inspect the parent project just to learn the task shape.
- Keep the solution minimal. The intended fix is in `src/main.mjs`.

Relevant files:

- `src/main.mjs`: handwritten JavaScript host glue
- `clasp_worker_bridge.py`: worker-side Python implementation
- `clasp_service_pkg/__main__.py`: service-side Python implementation
- `test/python-interop.test.mjs`: exact required behavior

Preferred workflow:

1. Read `test/python-interop.test.mjs`.
2. Update `src/main.mjs`.
3. Run `node test/python-interop.test.mjs`.
