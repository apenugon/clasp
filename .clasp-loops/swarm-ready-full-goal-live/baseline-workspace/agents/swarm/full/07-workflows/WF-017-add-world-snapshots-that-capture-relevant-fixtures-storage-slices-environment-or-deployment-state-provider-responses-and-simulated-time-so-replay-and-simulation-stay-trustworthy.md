# WF-017 Add World Snapshots That Capture Relevant Fixtures, Storage Slices, Environment Or Deployment State, Provider Responses, And Simulated Time So Replay And Simulation Stay Trustworthy

## Goal

Add world snapshots that capture relevant fixtures, storage slices, environment or deployment state, provider responses, and simulated time so replay and simulation stay trustworthy

## Why

Long-running agent systems need durable state, replay, and supervised self-update before Clasp can claim real autonomy. This task belongs to the Durable Workflows And Hot Swap track.

## Scope

- Implement `WF-017` as one narrow slice of work: Add world snapshots that capture relevant fixtures, storage slices, environment or deployment state, provider responses, and simulated time so replay and simulation stay trustworthy
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

- `WF-016`

## Acceptance

- `WF-017` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
