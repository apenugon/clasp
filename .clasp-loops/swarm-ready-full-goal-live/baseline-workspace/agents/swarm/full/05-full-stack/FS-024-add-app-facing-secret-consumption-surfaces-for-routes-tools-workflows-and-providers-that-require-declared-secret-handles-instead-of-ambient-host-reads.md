# FS-024 Add App-Facing Secret-Consumption Surfaces For Routes, Tools, Workflows, And Providers That Require Declared Secret Handles Instead Of Ambient Host Reads

## Goal

Add app-facing secret-consumption surfaces for routes, tools, workflows, and providers that require declared secret handles instead of ambient host reads

## Why

Clasp needs one shared app surface that spans backend, frontend, workers, and eventually mobile. This task belongs to the Full-Stack Runtime And App Layer track.

## Scope

- Implement `FS-024` as one narrow slice of work: Add app-facing secret-consumption surfaces for routes, tools, workflows, and providers that require declared secret handles instead of ambient host reads
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

- `FS-023`

## Acceptance

- `FS-024` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
