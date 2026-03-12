# CP-003 Design Declarations For Hooks And Lifecycle Triggers

## Goal

Design declarations for hooks and lifecycle triggers

## Why

The agent platform only becomes real when permissions, commands, hooks, agents, and policies are first-class declarations. This task belongs to the Control Plane Declarations track.

## Scope

- Implement `CP-003` as one narrow slice of work: Design declarations for hooks and lifecycle triggers
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/`
- `runtime/`
- `scripts/`
- `docs/`
- `agents/`
- `test/Main.hs`

## Dependencies

- `CP-002`

## Acceptance

- `CP-003` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
