# BM-025 Add Interop-Boundary Benchmarks That Measure Unsafe-Refinement Friction And Root-Cause Blame Quality For Unexpected Foreign Values

## Goal

Add interop-boundary benchmarks that measure unsafe-refinement friction and root-cause blame quality for unexpected foreign values

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-025` as one narrow slice of work: Add interop-boundary benchmarks that measure unsafe-refinement friction and root-cause blame quality for unexpected foreign values
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `BM-024`

## Acceptance

- `BM-025` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
