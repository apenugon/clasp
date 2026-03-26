# Task: Repair The Handwritten Authorization And Data-Access Surface Without Weakening Proof Gates

This repository models one narrow handwritten JavaScript benchmark around protected customer access.

The current access helpers and policy metadata are too incomplete for the mirrored authorization/data-access scenario. Fix the local implementation so the benchmark proves all of the following at once:

- protected reads require an explicit policy proof
- protected writes require an explicit policy proof under `SupportAccess`
- protected field disclosure for `contactEmail` requires an explicit policy proof and keeps the disclosure metadata aligned with the proof

## Working Guidance

- This task is intentionally local to the workspace.
- Start with `test/authorization-data-access.test.mjs` and `src/main.mjs`.
- Keep the fix local to `src/main.mjs`.

## Requirements

- Preserve the exact denial strings for missing proofs and mismatched proofs.
- The successful write proof must be issued under `SupportAccess`.
- The successful disclosure proof must expose `contactEmail`.
- The disclosure metadata must keep `classificationPolicy = "SupportAccess"` and `projectionSource = "Customer"`.
- The disclosed `contactEmail` field must stay classified as `pii`.

## Constraints

- Keep the codebase small and readable.
- Do not patch the test to bypass the missing proof configuration.

## Acceptance

The task is complete when `node test/authorization-data-access.test.mjs` passes.
