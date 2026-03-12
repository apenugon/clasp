# BM-024 Add Foreign-Package Interop Benchmarks That Compare Compiler-Managed Npm, Python, And Rust Usage Against Handwritten Host Glue On The Same Tasks

## Goal

Add foreign-package interop benchmarks that compare compiler-managed `npm`, `Python`, and `Rust` usage against handwritten host glue on the same tasks

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-024` as one narrow slice of work: Add foreign-package interop benchmarks that compare compiler-managed `npm`, `Python`, and `Rust` usage against handwritten host glue on the same tasks
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `BM-023`
- `FS-022`

## Acceptance

- `BM-024` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
