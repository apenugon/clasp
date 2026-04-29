# Benchmark Workspace Guidance

This task is intentionally local to this workspace.

- Stay inside this workspace unless `bash scripts/verify.sh` fails in a way that clearly points to a compiler, runtime, or benchmark harness bug.
- Start with `Main.clasp`, `Process.clasp`, and `scripts/verify.sh`.
- Keep the remediation bounded. The accepted change should stay on the legal-assistant slice and its direct verification path.
- Use `bash scripts/verify.sh` for acceptance.
