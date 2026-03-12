# TY-016 Add Boundary-Only Dynamic Or Unknown Foreign Values With Explicit Unsafe Refinement And Blame-Carrying Diagnostics

## Goal

Add boundary-only `Dynamic` or `Unknown` foreign values with explicit unsafe refinement and blame-carrying diagnostics

## Why

Clasp needs stronger typing and more useful diagnostics than mainstream baseline stacks if the language thesis is going to hold up. This task belongs to the Type System And Diagnostics track.

## Scope

- Implement `TY-016` as one narrow slice of work: Add boundary-only `Dynamic` or `Unknown` foreign values with explicit unsafe refinement and blame-carrying diagnostics
- Add or update regression coverage for the new behavior
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

- `TY-015`

## Acceptance

- `TY-016` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
