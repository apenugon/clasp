# CP-020 Add Affected-Surface Verification Planning That Maps A Candidate Change To The Exact Tests, Evals, Simulations, Proofs, Policies, Migrations, And Rollout Gates That Should Run First

## Goal

Add affected-surface verification planning that maps a candidate change to the exact tests, evals, simulations, proofs, policies, migrations, and rollout gates that should run first

## Why

The agent platform only becomes real when permissions, commands, hooks, agents, and policies are first-class declarations. This task belongs to the Control Plane Declarations track.

## Scope

- Implement `CP-020` as one narrow slice of work: Add affected-surface verification planning that maps a candidate change to the exact tests, evals, simulations, proofs, policies, migrations, and rollout gates that should run first
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/`
- `runtime/`
- `scripts/`
- `docs/`
- `agents/`
- `test/Main.hs`

## Dependencies

- `CP-019`

## Acceptance

- `CP-020` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
