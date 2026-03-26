# Task: Repair the Clasp Control Plane Without Breaking Least Privilege

The repository models one small repo-level control plane in `Clasp`.

The current declarations are too restrictive for the verifier flow and too incomplete for permission containment checks. Fix the control-plane surface without widening it beyond the required least-privilege shape.

## Working Guidance

- This task is intentionally local to the workspace.
- Start with `test/control-plane.test.mjs` and `Main.clasp`.
- Do not inspect the parent repo unless `bash scripts/verify.sh` exposes a compiler/runtime issue rather than a task-repo issue.
- Keep the solution declarative. The intended fix is in the `Clasp` control-plane declarations, not in the JavaScript test harness.

## Requirements

- Keep the builder agent, hook, tool, verifier, and merge gate wired together.
- The repo guide must tell the agent to stay inside the current checkout and to run `bash scripts/verify-all.sh` before finishing.
- The builder instructions must still tell the agent to inspect the repo first and then run the merge gate.
- The role must use `approval: on_request` and `sandbox: workspace_write`.
- The policy must allow exactly the control-plane actions needed by the scenario:
  - file access under `/workspace`
  - network access to `api.openai.com`
  - process execution for `rg` and `bash`
  - secret access for `OPENAI_API_KEY`
- Do not grant permissions for `/tmp`, `git`, `example.com`, or `AWS_SECRET_ACCESS_KEY`.
- The end-to-end demo in the test should still show one allowed inspect step and one allowed verification step.

## Constraints

- Keep the codebase small and readable.
- Preserve the existing hook/tool/verifier/merge-gate structure.
- Do not patch the JavaScript test or demo to bypass missing declarations.

## Acceptance

The task is complete when `bash scripts/verify.sh` passes.
