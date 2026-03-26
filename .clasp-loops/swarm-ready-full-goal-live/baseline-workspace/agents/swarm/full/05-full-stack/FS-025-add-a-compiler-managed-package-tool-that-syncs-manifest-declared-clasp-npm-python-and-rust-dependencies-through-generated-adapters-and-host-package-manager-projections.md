# FS-025 Add A Compiler-Managed Package Tool That Syncs Manifest-Declared Clasp, Npm, Python, And Rust Dependencies Through Generated Adapters And Host Package-Manager Projections

## Goal

Add a compiler-managed package tool that syncs manifest-declared `Clasp`, `npm`, `Python`, and `Rust` dependencies through generated adapters and host package-manager projections

## Why

Clasp needs one shared app surface that spans backend, frontend, workers, and eventually mobile. This task belongs to the Full-Stack Runtime And App Layer track.

## Scope

- Implement `FS-025` as one narrow slice of work: Add a compiler-managed package tool that syncs manifest-declared `Clasp`, `npm`, `Python`, and `Rust` dependencies through generated adapters and host package-manager projections
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
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

- `TY-027`
- `TY-028`
- `FS-020`
- `FS-021`
- `FS-022`

## Acceptance

- `FS-025` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
