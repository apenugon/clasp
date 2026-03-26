# TY-020 Add Obligation-Discharge Guidance So Unresolved Proofs, Unsafe Boundaries, And Refinement Failures Report The Concrete Missing Evidence, Legal Refinement Options, And Remaining Human Or Agent Choice Points

## Goal

Add obligation-discharge guidance so unresolved proofs, unsafe boundaries, and refinement failures report the concrete missing evidence, legal refinement options, and remaining human or agent choice points

## Why

Clasp needs stronger typing and more useful diagnostics than mainstream baseline stacks if the language thesis is going to hold up. This task belongs to the Type System And Diagnostics track.

## Scope

- Implement `TY-020` as one narrow slice of work: Add obligation-discharge guidance so unresolved proofs, unsafe boundaries, and refinement failures report the concrete missing evidence, legal refinement options, and remaining human or agent choice points
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/Core.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Diagnostic.hs`
- `src/Clasp/Lower.hs`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`

## Dependencies

- `TY-019`

## Acceptance

- `TY-020` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
