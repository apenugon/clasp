# BM-010 Add External-Objective Adaptation Benchmarks

## Goal

Add external-objective adaptation benchmarks

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-010` as one narrow slice of work: Add external-objective adaptation benchmarks
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `EO-007`

## Acceptance

- `BM-010` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
