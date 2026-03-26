# FS-017 Add Explicit Page-Render Projection Modes So Default SSR HTML Stays Stable While Machine Metadata Is Emitted Through Sidecar Artifacts Or Opt-In Surfaces

## Goal

Add explicit page-render projection modes so default SSR HTML stays stable while machine metadata is emitted through sidecar artifacts or opt-in surfaces

## Why

Clasp needs one shared app surface that spans backend, frontend, workers, and eventually mobile. This task belongs to the Full-Stack Runtime And App Layer track.

## Scope

- Implement `FS-017` as one narrow slice of work: Add explicit page-render projection modes so default SSR HTML stays stable while machine metadata is emitted through sidecar artifacts or opt-in surfaces
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

- `FS-017` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
