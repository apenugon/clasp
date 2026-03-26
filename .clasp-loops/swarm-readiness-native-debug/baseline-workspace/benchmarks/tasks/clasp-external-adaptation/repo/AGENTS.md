# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `bash scripts/verify.sh` fails in a way that clearly points to a compiler or runtime bug.
- Start with `test/objective.test.mjs`, then repair `demo.mjs`.
- Keep the remediation bounded. The accepted change should stay on the observed prompt and benchmark test only.
- Use `bash scripts/verify.sh` for acceptance.
