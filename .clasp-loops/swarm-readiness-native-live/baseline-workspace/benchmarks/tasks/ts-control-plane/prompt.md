# Task: Repair the TypeScript Control Plane Without Breaking Least Privilege

The repository models one small handwritten repo-level control plane in `TypeScript`.

The current declarations are too restrictive for the verifier flow and too incomplete for permission containment checks. Fix the control-plane surface without widening it beyond the required least-privilege shape.

## Working Guidance

- This task is intentionally local to the workspace.
- Start with `test/control-plane.test.mjs` and `src/controlPlane.ts`.
- Keep the solution explicit and readable. The intended fix is in the typed control-plane source, not in the test.

## Requirements

- Keep the builder agent, hook, tool, verifier, and merge gate wired together.
- The repo guide must tell the agent to stay inside the current checkout and to run `bash scripts/verify-all.sh` before finishing.
- The builder instructions must still tell the agent to inspect the repo first and then run the merge gate.
- The role must use `approvalPolicy: "on_request"` and `sandboxPolicy: "workspace_write"`.
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
- Do not patch the test to bypass missing declarations.

## Acceptance

The task is complete when `npm test` passes.
