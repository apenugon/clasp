# DB-002 Add A Typed SQLite Connection/Runtime Surface

## Goal

Add a typed SQLite connection/runtime surface

## Why

SQLite is the first persistence milestone after the app and language surfaces are already credible. This task belongs to the SQLite Storage track.

## Scope

- Implement `DB-002` as one narrow slice of work: Add a typed SQLite connection/runtime surface
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/`
- `runtime/`
- `examples/`
- `benchmarks/`
- `docs/`
- `test/`

## Dependencies

- `DB-001`

## Acceptance

- `DB-002` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
