# SW-002 Lane Queue Tests

## Goal

Add tests for the new worktree-based lane supervisor behavior.

## Why

The control plane should be regression-tested before the swarm starts chewing through compiler work.

## Scope

- Add tests for lane task discovery
- Add tests for stopped status output
- Add tests for stale pid handling
- Add tests or scripted checks for merge-lock serialization behavior where feasible

## Likely Files

- `scripts/test-swarm-control.sh`
- `scripts/clasp-swarm-start.sh`
- `scripts/clasp-swarm-status.sh`
- `scripts/clasp-swarm-stop.sh`
- `scripts/clasp-swarm-common.sh`

## Dependencies

- `SW-001`

## Acceptance

- Control-plane tests cover the core lane queue behaviors
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
