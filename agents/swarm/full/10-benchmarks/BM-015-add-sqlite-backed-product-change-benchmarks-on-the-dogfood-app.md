# BM-015 Add SQLite-Backed Product-Change Benchmarks On The Dogfood App

## Goal

Add SQLite-backed product-change benchmarks on the dogfood app

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-015` as one narrow slice of work: Add SQLite-backed product-change benchmarks on the dogfood app
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `DB-006`

## Acceptance

- `BM-015` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
