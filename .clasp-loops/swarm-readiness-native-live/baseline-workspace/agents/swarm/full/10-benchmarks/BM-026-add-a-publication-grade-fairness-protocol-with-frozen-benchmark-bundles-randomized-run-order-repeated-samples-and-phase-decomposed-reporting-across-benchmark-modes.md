# BM-026 Add A Publication-Grade Fairness Protocol With Frozen Benchmark Bundles, Randomized Run Order, Repeated Samples, And Phase-Decomposed Reporting Across Benchmark Modes

## Goal

Add a publication-grade fairness protocol with frozen benchmark bundles, randomized run order, repeated samples, and phase-decomposed reporting across benchmark modes

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-026` as one narrow slice of work: Add a publication-grade fairness protocol with frozen benchmark bundles, randomized run order, repeated samples, and phase-decomposed reporting across benchmark modes
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `BM-025`

## Acceptance

- `BM-026` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
