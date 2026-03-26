# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `bash scripts/verify.sh` fails in a way that clearly points to a benchmark harness bug.
- Start with `test/objective.test.mjs`, then repair `src/objective.ts`.
- Keep the accepted remediation bounded to the observed prompt and benchmark test.
- Use `bash scripts/verify.sh` for acceptance.
