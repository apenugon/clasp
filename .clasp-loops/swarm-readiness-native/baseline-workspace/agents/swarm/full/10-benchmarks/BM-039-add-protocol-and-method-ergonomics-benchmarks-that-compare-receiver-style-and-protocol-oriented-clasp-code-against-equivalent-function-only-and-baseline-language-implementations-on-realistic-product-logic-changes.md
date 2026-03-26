# BM-039 Add Protocol-And-Method Ergonomics Benchmarks That Compare Receiver-Style And Protocol-Oriented Clasp Code Against Equivalent Function-Only And Baseline-Language Implementations On Realistic Product Logic Changes

## Goal

Add protocol-and-method ergonomics benchmarks that compare receiver-style and protocol-oriented Clasp code against equivalent function-only and baseline-language implementations on realistic product logic changes

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-039` as one narrow slice of work: Add protocol-and-method ergonomics benchmarks that compare receiver-style and protocol-oriented Clasp code against equivalent function-only and baseline-language implementations on realistic product logic changes
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

- `TY-025`
- `TY-026`

## Acceptance

- `BM-039` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
