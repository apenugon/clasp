# SW-004 Add Run-State Summaries And Machine-Readable Status Output For The Supervisor

## Goal

Add run-state summaries and machine-readable status output for the supervisor

## Why

The swarm itself needs to be reliable before it can safely drive the rest of the project. This task belongs to the Swarm Infrastructure track.

## Scope

- Implement `SW-004` as one narrow slice of work: Add run-state summaries and machine-readable status output for the supervisor
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `agents/swarm/`
- `scripts/clasp-swarm-*.sh`
- `scripts/test-swarm-control.sh`
- `docs/clasp-project-plan.md`

## Dependencies

- `SW-003`

## Acceptance

- `SW-004` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
