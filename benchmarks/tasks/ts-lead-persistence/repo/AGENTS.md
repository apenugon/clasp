# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `bash scripts/verify.sh` fails in a way that clearly points to a benchmark harness or language-runtime bug.
- Use the local files as the source of truth.
- Keep the solution minimal and preserve the existing server-rendered route flow.
- Use only `bash scripts/verify.sh` for acceptance in this workspace.
- Do not edit generated artifacts directly; let the local verify script regenerate what it needs.

Preferred workflow:

1. Read `test/lead-app.test.mjs`.
2. Update `src/server/main.ts` and add any missing storage helper locally.
3. Rerun `bash scripts/verify.sh`.
