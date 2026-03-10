# SW-006 Add Worktree Lifecycle Cleanup And Stale-Run Garbage Collection

## Goal

Add worktree lifecycle cleanup and stale-run garbage collection

## Why

The swarm itself needs to be reliable before it can safely drive the rest of the project. This task belongs to the Swarm Infrastructure track.

## Scope

- Implement `SW-006` as one narrow slice of work: Add worktree lifecycle cleanup and stale-run garbage collection
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `agents/swarm/`
- `scripts/clasp-swarm-*.sh`
- `scripts/test-swarm-control.sh`
- `docs/clasp-project-plan.md`

## Dependencies

- `SW-005`

## Acceptance

- `SW-006` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
