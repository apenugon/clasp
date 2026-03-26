# Task: Repair the Clasp External-Objective Adaptation Demo

The repository models one bounded feedback-to-change loop on top of the Clasp lead app.

Start with `test/objective.test.mjs` and `demo.mjs`.

## Requirements

- Keep the feedback signal tied to the external objective `reply-rate`.
- Preserve the rejected over-broad route change.
- Keep the accepted remediation bounded to the observed prompt and benchmark test.
- The accepted remediation plan must contain exactly two steps.
- Do not widen the accepted target list beyond the prompt and benchmark test.
- Do not broaden the remediation beyond the observed lead path.

## Constraints

- Keep the change local to this workspace.
- Do not edit the copied Clasp app schema or runtime glue unless the verifier proves `demo.mjs` is insufficient.
- Use `bash scripts/verify.sh` for acceptance.
