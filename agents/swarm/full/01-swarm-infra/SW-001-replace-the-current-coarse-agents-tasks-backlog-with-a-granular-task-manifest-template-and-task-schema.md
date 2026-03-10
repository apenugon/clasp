# SW-001 Replace The Current Coarse Agents/Tasks Backlog With A Granular Task Manifest Template And Task Schema

## Goal

Replace the current coarse `agents/tasks` backlog with a granular task manifest template and task schema

## Why

The swarm itself needs to be reliable before it can safely drive the rest of the project. This task belongs to the Swarm Infrastructure track.

## Scope

- Implement `SW-001` as one narrow slice of work: Replace the current coarse `agents/tasks` backlog with a granular task manifest template and task schema
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `agents/swarm/`
- `scripts/clasp-swarm-*.sh`
- `scripts/test-swarm-control.sh`
- `docs/clasp-project-plan.md`

## Dependencies

- None

## Acceptance

- `SW-001` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
