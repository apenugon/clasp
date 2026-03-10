# SW-008 Add A Dashboard Or Summary Script For Pass Rate, Timeout Rate, And Mean Time Per Task Family

## Goal

Add a dashboard or summary script for pass rate, timeout rate, and mean time per task family

## Why

The swarm itself needs to be reliable before it can safely drive the rest of the project. This task belongs to the Swarm Infrastructure track.

## Scope

- Implement `SW-008` as one narrow slice of work: Add a dashboard or summary script for pass rate, timeout rate, and mean time per task family
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `agents/swarm/`
- `scripts/clasp-swarm-*.sh`
- `scripts/test-swarm-control.sh`
- `docs/clasp-project-plan.md`

## Dependencies

- `SW-007`

## Acceptance

- `SW-008` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
