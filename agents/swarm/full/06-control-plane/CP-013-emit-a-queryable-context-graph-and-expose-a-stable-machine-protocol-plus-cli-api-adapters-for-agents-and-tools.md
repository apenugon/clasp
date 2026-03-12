# CP-013 Emit A Queryable Context Graph And Expose A Stable Machine Protocol Plus CLI/API Adapters For Agents And Tools

## Goal

Emit a queryable context graph and expose a stable machine protocol plus CLI/API adapters for agents and tools

## Why

The agent platform only becomes real when permissions, commands, hooks, agents, and policies are first-class declarations. This task belongs to the Control Plane Declarations track.

## Scope

- Implement `CP-013` as one narrow slice of work: Emit a queryable context graph and expose a stable machine protocol plus CLI/API adapters for agents and tools
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

- `CP-012`

## Acceptance

- `CP-013` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
