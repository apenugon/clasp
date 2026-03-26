# FS-015 Emit Machine-Readable UI, Action, And Navigation Graph Artifacts For Page-Driven App Flows

## Goal

Emit machine-readable UI, action, and navigation graph artifacts for page-driven app flows

## Why

The benchmark task is mostly about tracing one shared change through forms, routes, pages, and rendered labels. A UI/action graph should make that path obvious in both `Raw Repo` and `File-Hinted` modes.

## Scope

- Implement `FS-015` as one focused slice of work on machine-readable UI/action/navigation artifacts
- Keep the first pass centered on the current page-driven benchmark slice
- Add or update regression coverage for the new behavior
- Update docs only where visible machine-facing output changes
- Avoid unrelated frontend expansion

## Likely Files

- `src/Clasp/Core.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `src/Clasp/Compiler.hs`
- `test/Main.hs`

## Dependencies

- `FS-013`
- `FS-014`

## Acceptance

- `FS-015` is implemented without breaking the benchmark slice or previously integrated tasks
- The compiler emits machine-readable UI/action/navigation artifacts for the benchmark app
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
