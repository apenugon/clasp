# Task: Repair the TypeScript External-Objective Adaptation Loop

The repository models one bounded feedback-to-change loop in a small TypeScript benchmark.

Start with `test/objective.test.mjs` and `src/objective.ts`.

## Requirements

- Keep the feedback signal tied to the external objective `reply-rate`.
- Preserve the rejected over-broad route change.
- Keep the accepted remediation bounded to the observed prompt and benchmark test.
- The accepted remediation plan must contain exactly two steps.
- Do not widen the accepted target list beyond the prompt and benchmark test.
- Do not broaden the remediation beyond the observed lead path.

## Constraints

- Keep the change local to this workspace.
- Do not change the test unless the verifier shows the benchmark itself is wrong.
- Use `bash scripts/verify.sh` for acceptance.
