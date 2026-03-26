# CP-013 Emit A Queryable Context Graph And Expose A Stable Machine Protocol Plus CLI/API Adapters For Agents And Tools

## Goal

Emit a queryable context graph and expose a stable machine protocol plus CLI/API adapters for agents and tools

## Why

`Raw Repo` mode will only become a durable `Clasp` advantage if the compiler can answer “what changes with this field?” directly. This task is the main discovery reduction lever on the benchmark path.

## Scope

- Implement `CP-013` as one focused slice of work on a queryable context graph and machine-oriented access path
- Prefer a benchmark-relevant first pass over a broad control-plane rollout
- Add or update regression coverage for the new behavior
- Update docs only where the visible machine interface changes
- Avoid unrelated control-plane expansion

## Likely Files

- `src/Clasp/Compiler.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `test/Main.hs`
- `docs/`

## Dependencies

- `TY-015`
- `FS-013`
- `FS-014`
- `FS-011`
- `SC-013`

## Acceptance

- `CP-013` is implemented without breaking the benchmark slice or previously integrated tasks
- Agents can query benchmark-relevant schemas, routes, pages, actions, and foreign/runtime edges through a stable machine-facing surface
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
