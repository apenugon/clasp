# WF-013 Build A Demo Workflow That Survives Restart And Controlled Module Replacement Under Supervision

## Goal

Build a demo workflow that survives restart and controlled module replacement under supervision

## Why

Long-running agent systems need durable state, replay, and supervised self-update before Clasp can claim real autonomy. This task belongs to the Durable Workflows And Hot Swap track.

## Scope

- Implement `WF-013` as one narrow slice of work: Build a demo workflow that survives restart and controlled module replacement under supervision
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/`
- `runtime/`
- `examples/`
- `test/Main.hs`
- `docs/`

## Dependencies

- `WF-012`

## Acceptance

- `WF-013` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
