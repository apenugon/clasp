# BM-008 Add Hot-Swap And Self-Update Benchmarks, Including Supervised Upgrades, Rollback, And Version-Drain Behavior

## Goal

Add hot-swap and self-update benchmarks, including supervised upgrades, rollback, and version-drain behavior

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-008` as one narrow slice of work: Add hot-swap and self-update benchmarks, including supervised upgrades, rollback, and version-drain behavior
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

- `WF-010`

## Acceptance

- `BM-008` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
