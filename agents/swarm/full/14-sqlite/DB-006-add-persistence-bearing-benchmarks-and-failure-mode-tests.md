# DB-006 Add Persistence-Bearing Benchmarks And Failure-Mode Tests

## Goal

Add persistence-bearing benchmarks and failure-mode tests

## Why

SQLite is the first storage backend after the app and language surfaces are already credible. The benchmark story needs persistence-bearing tasks that expose storage correctness and failure modes, not just CRUD shape changes. This task belongs to the SQLite Storage track.

## Scope

- Implement `DB-006` as one narrow slice of work: add persistence-bearing benchmarks and failure-mode tests for the compiler-owned storage model.
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

- `DB-005`

## Acceptance

- `DB-006` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
