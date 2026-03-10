# EO-006 Add Traceability From Runtime Signals Back To Routes, Prompts, Workflows, Tests, And Policies

## Goal

Add traceability from runtime signals back to routes, prompts, workflows, tests, and policies

## Why

Clasp’s long-term differentiator is the ability to relate runtime and business signals back to typed code and policy changes. This task belongs to the External-Objective Adaptation track.

## Scope

- Implement `EO-006` as one narrow slice of work: Add traceability from runtime signals back to routes, prompts, workflows, tests, and policies
- Add or update regression coverage for the new behavior
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

- `EO-005`

## Acceptance

- `EO-006` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
