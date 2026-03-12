# FS-022 Add Compiler-Managed Rust Crate And Native-Library Interop With Generated Bindings, Capability Metadata, And Target-Aware Build Integration

## Goal

Add compiler-managed `Rust` crate and native-library interop with generated bindings, capability metadata, and target-aware build integration

## Why

Clasp needs one shared app surface that spans backend, frontend, workers, and eventually mobile. This task belongs to the Full-Stack Runtime And App Layer track.

## Scope

- Implement `FS-022` as one narrow slice of work: Add compiler-managed `Rust` crate and native-library interop with generated bindings, capability metadata, and target-aware build integration
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

- `FS-021`

## Acceptance

- `FS-022` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
