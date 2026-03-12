# FS-020 Add Compiler-Managed Npm And TypeScript Package Imports With Declaration Ingestion, Typed Manifests, And Generated Host Adapters

## Goal

Add compiler-managed `npm` and `TypeScript` package imports with declaration ingestion, typed manifests, and generated host adapters

## Why

Clasp needs one shared app surface that spans backend, frontend, workers, and eventually mobile. This task belongs to the Full-Stack Runtime And App Layer track.

## Scope

- Implement `FS-020` as one narrow slice of work: Add compiler-managed `npm` and `TypeScript` package imports with declaration ingestion, typed manifests, and generated host adapters
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

- `FS-019`

## Acceptance

- `FS-020` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
