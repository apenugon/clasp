# BM-017 Add End-To-End Correctness Benchmarks For Invariants, State Transitions, And Storage-Backed Changes

## Goal

Add end-to-end correctness benchmarks for invariants, state transitions, and storage-backed changes

## Why

The strongest claim for `Clasp` is not just that agents write less glue. It is that they ship fewer invalid states and catch more cross-layer correctness defects before runtime. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-017` as one narrow slice of work: add benchmark tasks that stress invariants, state transitions, and storage-backed changes.
- Include at least one task that adds or tightens a constrained field, one that forbids an illegal transition, and one that changes a storage rule or migration.
- Keep the scenarios mirrored across `Clasp` and the baseline repo so the comparison remains fair.
- Add or update regression coverage for benchmark packaging and result-shape expectations.
- Update docs or examples only where the new surface changes visible behavior.
- Avoid unrelated harness refactors or broad benchmark-suite redesign.

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `BM-015`
- `FS-013`
- `SC-014`
- `DB-009`

## Acceptance

- The benchmark suite includes mirrored correctness-heavy tasks for constrained values, state transitions, and storage-backed changes.
- Benchmark packaging and result metadata remain reproducible and comparable across language baselines.
- Tests or regressions cover the new benchmark behavior.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
