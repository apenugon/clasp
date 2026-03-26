# Task: Repair The Clasp Authorization And Data-Access Surface Without Weakening Proof Gates

This repository models one narrow `Clasp` benchmark around protected customer access.

The current declarations are too incomplete for the mirrored authorization/data-access scenario. Fix the local `Clasp` surface so the benchmark proves all of the following at once:

- protected reads require an explicit policy proof
- protected writes require an explicit policy proof under `SupportAccess`
- protected field disclosure for `contactEmail` requires an explicit policy proof and keeps the projection metadata aligned with the policy proof

## Working Guidance

- This task is intentionally local to the workspace.
- Start with `test/authorization-data-access.test.mjs` and `Main.clasp`.
- Keep the fix declarative. The intended change is in `Main.clasp`, not in the JavaScript demo or test.

## Requirements

- Preserve the exact denial strings for missing proofs and mismatched proofs.
- The successful write proof must be issued under `SupportAccess`.
- The successful disclosure proof must expose `contactEmail`.
- The compiled `SupportCustomer` projection must keep `classificationPolicy = "SupportAccess"` and `projectionSource = "Customer"`.
- The disclosed `contactEmail` field must stay classified as `pii`.

## Constraints

- Keep the codebase small and readable.
- Do not patch the JavaScript demo or test to bypass the missing declaration problem.

## Acceptance

The task is complete when `bash scripts/verify.sh` passes.
