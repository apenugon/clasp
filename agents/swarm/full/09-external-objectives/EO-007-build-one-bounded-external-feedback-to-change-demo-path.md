# EO-007 Build One Bounded External-Feedback-To-Change Demo Path

## Goal

Build one bounded external-feedback-to-change demo path.

## Why

Clasp’s long-term differentiator is the ability to relate runtime and business signals back to typed code and policy changes. This task belongs to the External-Objective Adaptation track.

## Scope

- Build one concrete demo path that starts from typed external feedback and ends at a bounded change recommendation or rollout action.
- Reuse the existing lead-priority surface where possible instead of inventing a new domain from scratch.
- The path should show: feedback ingestion, traceability back to one named route or prompt/policy surface, and one bounded recommended change or gated rollout decision.
- Keep this task bounded to traceability and decision output. It does not need to perform general autonomous code rewriting.
- Add or update regression coverage for the feedback-to-traceability-to-decision path.
- Update docs or examples only where the new surface changes visible behavior.
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `examples/lead-app/`
- `benchmarks/tasks/clasp-lead-priority/`
- `runtime/`
- `test/Main.hs`
- `docs/clasp-project-plan.md`

## Dependencies

- `EO-006`

Assume `EO-001` through `EO-006` have already landed domain-object declarations, goals/rollouts, feedback ingestion, and traceability metadata.

## Acceptance

- A checked-in demo path exists using one named domain surface, preferably the existing lead-priority example.
- Given one typed external feedback input, the demo resolves to one named affected declaration or bounded set of declarations.
- The demo emits one bounded change recommendation or rollout decision rather than an open-ended edit plan.
- Tests or regressions cover the success path from feedback ingestion through traceability to decision output.
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
