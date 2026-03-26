# Task: Repair the Clasp Durable Workflow Self-Update Flow

The repository models one small durable workflow benchmark for supervised self-update in `Clasp`.

The current demo exercises only the happy path. Extend it so the benchmark covers bounded overlap, version draining, health-gated activation, and both automatic and manual rollback behavior.

## Working Guidance

- This task is intentionally local to the workspace.
- Start with `test/durable-workflow.test.mjs` and `demo.mjs`.
- Do not inspect the parent repo unless `bash scripts/verify.sh` exposes a benchmark harness or runtime bug rather than a task-repo bug.
- Keep the fix inside the local self-update demo. Do not patch the test to relax the scenario.

## Requirements

- Preserve the compiled `Main.clasp` and `Main.next.clasp` module pairing.
- Keep the target module patched so the new version explicitly accepts the old version for hot swap.
- Begin a bounded overlap window before promotion so the demo reports version-drain metadata.
- Perform supervised operator handoff and drain the old version before activation.
- Keep the healthy activation path reporting rollback availability and tagged target version metadata.
- Add a warmup block path where a failing health check reports `probe-warming` without immediately rolling back.
- Add an automatic rollback path triggered by `health_check_failed`.
- Add a manual rollback path triggered by `error_budget` after a successful activation.
- Preserve rollback audit metadata and the final retirement summary for the drained old version.

## Constraints

- Keep the codebase small and readable.
- Preserve the existing runtime import and compiled-module loading flow.
- Do not bypass the worker runtime contract with handwritten fake results.

## Acceptance

The task is complete when `bash scripts/verify.sh` passes.
