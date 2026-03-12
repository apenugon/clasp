# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `bash scripts/verify.sh` fails in a way that clearly points to a benchmark harness or language-runtime bug.
- Use the local files as the source of truth.
- Keep the solution minimal and preserve the existing server-rendered route flow.
- Use only `bash scripts/verify.sh` for acceptance in this workspace.
- Do not edit generated artifacts directly; let the local verify script regenerate what it needs.

Preferred workflow:

1. Read `test/lead-app.test.mjs`.
2. Update the shared lead contract and rendering surface first.
3. Update the local server logic only if the shared-contract change requires it.
4. Rerun `bash scripts/verify.sh`.
