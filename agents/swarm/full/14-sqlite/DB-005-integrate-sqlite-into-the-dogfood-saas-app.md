# DB-005 Integrate SQLite Into The Dogfood SaaS App

## Goal

Integrate SQLite into the dogfood SaaS app

## Why

SQLite is the first persistence milestone after the app and language surfaces are already credible. This task belongs to the SQLite Storage track.

## Scope

- Implement `DB-005` as one narrow slice of work: Integrate SQLite into the dogfood SaaS app
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

- `DB-004`

## Acceptance

- `DB-005` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
