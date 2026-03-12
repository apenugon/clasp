# FS-016 Add Compiler-Known Authorization Requirements And Proof-Carrying Access For Routes, Pages, Actions, Queries, And Tools

## Goal

Add compiler-known authorization requirements and proof-carrying access for routes, pages, actions, queries, and tools

## Why

Clasp needs one shared app surface that spans backend, frontend, workers, and eventually mobile. This task belongs to the Full-Stack Runtime And App Layer track.

## Scope

- Implement `FS-016` as one narrow slice of work: Add compiler-known authorization requirements and proof-carrying access for routes, pages, actions, queries, and tools
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/Emit/JavaScript.hs`
- `runtime/bun/`
- `examples/`
- `benchmarks/`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`

## Dependencies

- `FS-015`

## Acceptance

- `FS-016` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
