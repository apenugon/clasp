# SW-007 Add Task Batching And Dependency Labels So Multiple Agents Can Be Launched Safely In Parallel

## Goal

Add task batching and dependency labels so multiple agents can be launched safely in parallel

## Why

The swarm itself needs to be reliable before it can safely drive the rest of the project. This task belongs to the Swarm Infrastructure track.

## Scope

- Implement `SW-007` as one narrow slice of work: Add task batching and dependency labels so multiple agents can be launched safely in parallel
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `agents/swarm/`
- `scripts/clasp-swarm-*.sh`
- `scripts/test-swarm-control.sh`
- `docs/clasp-project-plan.md`

## Dependencies

- `SW-006`

## Acceptance

- `SW-007` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
