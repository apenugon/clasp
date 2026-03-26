# WF-015 Add First-Class Temporal Semantics For Deadlines, TTLs, Expirations, Schedules, Rollout Windows, Cache Staleness, And Delegated-Capability Expiry With Simulated-Time Support

## Goal

Add first-class temporal semantics for deadlines, TTLs, expirations, schedules, rollout windows, cache staleness, and delegated-capability expiry with simulated-time support

## Why

Long-running agent systems need durable state, replay, and supervised self-update before Clasp can claim real autonomy. This task belongs to the Durable Workflows And Hot Swap track.

## Scope

- Implement `WF-015` as one narrow slice of work: Add first-class temporal semantics for deadlines, TTLs, expirations, schedules, rollout windows, cache staleness, and delegated-capability expiry with simulated-time support
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/`
- `runtime/`
- `examples/`
- `test/Main.hs`
- `docs/`

## Dependencies

- `WF-014`

## Acceptance

- `WF-015` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
