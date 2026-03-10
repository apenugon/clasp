# SW-002 Add Tests For Autopilot Queue Behavior, Especially Blocked-Task Handling, Workaround Generation, And Restart Behavior

## Goal

Add tests for autopilot queue behavior, especially blocked-task handling, workaround generation, and restart behavior

## Why

The swarm itself needs to be reliable before it can safely drive the rest of the project. This task belongs to the Swarm Infrastructure track.

## Scope

- Implement `SW-002` as one narrow slice of work: Add tests for autopilot queue behavior, especially blocked-task handling, workaround generation, and restart behavior
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `agents/swarm/`
- `scripts/clasp-swarm-*.sh`
- `scripts/test-swarm-control.sh`
- `docs/clasp-project-plan.md`

## Dependencies

- `SW-001`

## Acceptance

- `SW-002` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
