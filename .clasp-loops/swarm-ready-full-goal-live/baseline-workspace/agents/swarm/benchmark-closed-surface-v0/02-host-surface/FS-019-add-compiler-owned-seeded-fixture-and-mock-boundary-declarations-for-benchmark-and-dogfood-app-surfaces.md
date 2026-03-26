# FS-019 Add Compiler-Owned Seeded Fixture And Mock-Boundary Declarations For Benchmark And Dogfood App Surfaces

## Goal

Add compiler-owned seeded fixture and mock-boundary declarations for benchmark and dogfood app surfaces

## Why

Clasp needs one shared app surface that spans backend, frontend, workers, and eventually mobile. This task belongs to the Full-Stack Runtime And App Layer track.

## Scope

- Implement `FS-019` as one narrow slice of work: Add compiler-owned seeded fixture and mock-boundary declarations for benchmark and dogfood app surfaces
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

- `FS-018`

## Acceptance

- `FS-019` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
