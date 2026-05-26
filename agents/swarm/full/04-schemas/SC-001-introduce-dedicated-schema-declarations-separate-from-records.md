# SC-001 Introduce Dedicated Schema Declarations Separate From Records

## Goal

Introduce dedicated schema declarations separate from records

## Why

Generated trust-boundary handling is one of the main reasons Clasp should outperform baseline stacks in agent-driven work. This task belongs to the Schemas And Trust Boundaries track.

## Scope

- Implement `SC-001` as one narrow slice of work: Introduce dedicated schema declarations separate from records
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Compiler/Checker.clasp`
- `src/Compiler/Lower.clasp`
- `src/Compiler/Emit/JavaScript.clasp`
- `runtime/`
- `scripts/`
- `test/`
- `docs/clasp-spec-v0.md`
- `examples/`

## Dependencies

- `TY-010`

## Acceptance

- `SC-001` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
