# BM-009 Add Syntax-Form A/B Benchmarks For Compact Vs More Verbose Surfaces

## Goal

Add syntax-form A/B benchmarks for compact vs more verbose surfaces

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-009` as one narrow slice of work: Add syntax-form A/B benchmarks for compact vs more verbose surfaces
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `LG-019`

## Acceptance

- `BM-009` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
