# EO-003 Add Experiment And Rollout Declarations

## Goal

Add experiment and rollout declarations

## Why

Clasp’s long-term differentiator is the ability to relate runtime and business signals back to typed code and policy changes. This task belongs to the External-Objective Adaptation track.

## Scope

- Implement `EO-003` as one narrow slice of work: Add experiment and rollout declarations
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/`
- `runtime/`
- `examples/`
- `benchmarks/`
- `test/Main.hs`
- `docs/`

## Dependencies

- `EO-002`

## Acceptance

- `EO-003` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
