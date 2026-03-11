# DB-003 Add Typed Query And Row-Mapping Support

## Goal

Add typed query and row-mapping support

## Why

SQLite is the first storage backend after the app and language surfaces are already credible. The default query path should be typed and compiler-owned rather than handwritten string SQL. This task belongs to the SQLite Storage track.

## Scope

- Implement `DB-003` as one narrow slice of work: add typed query and row-mapping support as part of the language-native storage model.
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

- `DB-002`

## Acceptance

- `DB-003` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
