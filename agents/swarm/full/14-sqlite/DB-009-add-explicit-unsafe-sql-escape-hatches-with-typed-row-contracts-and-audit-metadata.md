# DB-009 Add Explicit Unsafe SQL Escape Hatches With Typed Row Contracts And Audit Metadata

## Goal

Add explicit unsafe SQL escape hatches with typed row contracts and audit metadata

## Why

SQLite is the first persistence milestone after the app and language surfaces are already credible. This task belongs to the SQLite Storage track.

## Scope

- Implement `DB-009` as one narrow slice of work: Add explicit unsafe SQL escape hatches with typed row contracts and audit metadata
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

- `DB-008`

## Acceptance

- `DB-009` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
