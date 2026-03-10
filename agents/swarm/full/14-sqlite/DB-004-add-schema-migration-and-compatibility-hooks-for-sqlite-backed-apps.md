# DB-004 Add Schema Migration And Compatibility Hooks For SQLite-Backed Apps

## Goal

Add schema migration and compatibility hooks for SQLite-backed apps

## Why

SQLite is the first persistence milestone after the app and language surfaces are already credible. This task belongs to the SQLite Storage track.

## Scope

- Implement `DB-004` as one narrow slice of work: Add schema migration and compatibility hooks for SQLite-backed apps
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

- `DB-003`

## Acceptance

- `DB-004` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
