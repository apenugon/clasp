# BM-023 Add Benchmark-Prep Semantic Packs And Workspace Guidance Generated From Context, AIR, And UI Graph Artifacts

## Goal

Add benchmark-prep semantic packs and workspace guidance generated from context, AIR, and UI graph artifacts

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-023` as one narrow slice of work: Add benchmark-prep semantic packs and workspace guidance generated from context, AIR, and UI graph artifacts
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `BM-022`
- `CP-013`
- `FS-015`
- `TY-015`

## Acceptance

- `BM-023` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
