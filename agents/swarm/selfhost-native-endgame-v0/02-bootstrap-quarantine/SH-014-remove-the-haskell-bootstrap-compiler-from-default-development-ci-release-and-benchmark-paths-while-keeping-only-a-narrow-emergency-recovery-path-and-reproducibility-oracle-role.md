# SH-014 Remove The Haskell Bootstrap Compiler From Default Development, CI, Release, And Benchmark Paths While Keeping Only A Narrow Emergency Recovery Path And Reproducibility Oracle Role

## Goal

Remove the Haskell bootstrap compiler from default development, CI, release, and benchmark paths while keeping only a narrow emergency recovery path and reproducibility oracle role

## Why

Clasp should eventually be able to carry its own compiler once the language and runtime are mature enough. This task belongs to the Self-Hosting track.

## Scope

- Implement `SH-014` as one narrow slice of work: Remove the Haskell bootstrap compiler from default development, CI, release, and benchmark paths while keeping only a narrow emergency recovery path and reproducibility oracle role
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/`
- `examples/`
- `docs/`
- `test/`
- `benchmarks/`

## Dependencies

- `SH-013`

## Acceptance

- `SH-014` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
