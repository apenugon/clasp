# SW-007 Worktree retry

## Goal

Retry the lane after a builder leaves the task workspace without usable Git metadata.

## Why

Regression coverage for builder-side workspace corruption should stay end-to-end.

## Scope

- Exercise one retry after an infra failure

## Likely Files

- `scripts/clasp-swarm-lane.sh`

## Dependencies

- None

## Acceptance

- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
