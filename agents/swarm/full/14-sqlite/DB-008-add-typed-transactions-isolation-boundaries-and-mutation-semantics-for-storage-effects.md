# DB-008 Add Typed Transactions, Isolation Boundaries, And Mutation Semantics For Storage Effects

## Goal

Add typed transactions, isolation boundaries, and mutation semantics for storage effects

## Why

SQLite is the first persistence milestone after the app and language surfaces are already credible. This task belongs to the SQLite Storage track.

## Scope

- Implement `DB-008` as one narrow slice of work: Add typed transactions, isolation boundaries, and mutation semantics for storage effects
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

- `DB-007`

## Acceptance

- `DB-008` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
