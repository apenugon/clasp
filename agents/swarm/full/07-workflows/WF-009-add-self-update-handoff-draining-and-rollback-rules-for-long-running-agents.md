# WF-009 Add Self-Update Handoff, Draining, And Rollback Rules For Long-Running Agents

## Goal

Add self-update handoff, draining, and rollback rules for long-running agents

## Why

Long-running agent systems need durable state, replay, and supervised self-update before Clasp can claim real autonomy. This task belongs to the Durable Workflows And Hot Swap track.

## Scope

- Implement `WF-009` as one narrow slice of work: Add self-update handoff, draining, and rollback rules for long-running agents
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

- `WF-008`

## Acceptance

- `WF-009` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
