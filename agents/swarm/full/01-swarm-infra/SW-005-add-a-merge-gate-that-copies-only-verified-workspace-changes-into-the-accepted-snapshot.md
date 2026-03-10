# SW-005 Add A Merge Gate That Copies Only Verified Workspace Changes Into The Accepted Snapshot

## Goal

Add a merge gate that copies only verified workspace changes into the accepted snapshot

## Why

The swarm itself needs to be reliable before it can safely drive the rest of the project. This task belongs to the Swarm Infrastructure track.

## Scope

- Implement `SW-005` as one narrow slice of work: Add a merge gate that copies only verified workspace changes into the accepted snapshot
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `agents/swarm/`
- `scripts/clasp-swarm-*.sh`
- `scripts/test-swarm-control.sh`
- `docs/clasp-project-plan.md`

## Dependencies

- `SW-004`

## Acceptance

- `SW-005` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
