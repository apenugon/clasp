# NB-001 Define A Backend-Native IR Below The Current Lowered IR

## Goal

Define a backend-native IR below the current lowered IR

## Why

Clasp needs a path beyond JavaScript for backend and compiler workloads once the hosted path is proven. This task belongs to the Native Backend And Bytecode track.

## Scope

- Implement `NB-001` as one narrow slice of work: Define a backend-native IR below the current lowered IR
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/`
- `runtime/`
- `docs/`
- `test/`
- `benchmarks/`

## Dependencies

- `SH-010`

## Acceptance

- `NB-001` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
