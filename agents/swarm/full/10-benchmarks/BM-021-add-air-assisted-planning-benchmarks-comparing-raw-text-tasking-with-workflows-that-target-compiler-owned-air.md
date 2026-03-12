# BM-021 Add AIR-Assisted Planning Benchmarks Comparing Raw-Text Tasking With Workflows That Target Compiler-Owned AIR

## Goal

Add AIR-assisted planning benchmarks comparing raw-text tasking with workflows that target compiler-owned AIR

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-021` as one narrow slice of work: Add AIR-assisted planning benchmarks comparing raw-text tasking with workflows that target compiler-owned AIR
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `BM-020`

## Acceptance

- `BM-021` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
