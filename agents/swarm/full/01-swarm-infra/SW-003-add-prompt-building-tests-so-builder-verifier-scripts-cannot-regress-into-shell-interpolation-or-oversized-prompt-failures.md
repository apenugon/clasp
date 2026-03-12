# SW-003 Add Prompt-Building Tests So Builder/Verifier Scripts Cannot Regress Into Shell Interpolation Or Oversized Prompt Failures

## Goal

Add prompt-building tests so builder/verifier scripts cannot regress into shell interpolation or oversized prompt failures

## Why

The swarm itself needs to be reliable before it can safely drive the rest of the project. This task belongs to the Swarm Infrastructure track.

## Scope

- Implement `SW-003` as one narrow slice of work: Add prompt-building tests so builder/verifier scripts cannot regress into shell interpolation or oversized prompt failures
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `agents/swarm/`
- `scripts/clasp-swarm-*.sh`
- `scripts/test-swarm-control.sh`
- `docs/clasp-project-plan.md`

## Dependencies

- `SW-002`

## Acceptance

- `SW-003` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
