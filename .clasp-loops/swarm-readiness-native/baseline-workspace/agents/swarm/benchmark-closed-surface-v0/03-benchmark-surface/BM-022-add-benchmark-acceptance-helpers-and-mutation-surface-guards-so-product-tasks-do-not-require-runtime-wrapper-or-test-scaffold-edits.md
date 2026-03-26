# BM-022 Add Benchmark Acceptance Helpers And Mutation-Surface Guards So Product Tasks Do Not Require Runtime-Wrapper Or Test-Scaffold Edits

## Goal

Add benchmark acceptance helpers and mutation-surface guards so product tasks do not require runtime-wrapper or test-scaffold edits

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-022` as one narrow slice of work: Add benchmark acceptance helpers and mutation-surface guards so product tasks do not require runtime-wrapper or test-scaffold edits
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `FS-017`
- `FS-019`
- `FS-015`
- `CP-013`

## Acceptance

- `BM-022` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
