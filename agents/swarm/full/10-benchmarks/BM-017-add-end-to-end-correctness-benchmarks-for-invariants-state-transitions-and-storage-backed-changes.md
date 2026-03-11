# BM-017 Add End-To-End Correctness Benchmarks For Invariants, State Transitions, And Storage-Backed Changes

## Goal

Add end-to-end correctness benchmarks for invariants, state transitions, and storage-backed changes

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-017` as one narrow slice of work: Add end-to-end correctness benchmarks for invariants, state transitions, and storage-backed changes
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `BM-016`

## Acceptance

- `BM-017` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
