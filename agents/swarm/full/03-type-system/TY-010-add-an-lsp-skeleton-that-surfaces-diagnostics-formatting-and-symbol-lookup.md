# TY-010 Add An LSP Skeleton That Surfaces Diagnostics, Formatting, And Symbol Lookup

## Goal

Add an LSP skeleton that surfaces diagnostics, formatting, and symbol lookup

## Why

Clasp needs stronger typing and more useful diagnostics than mainstream baseline stacks if the language thesis is going to hold up. This task belongs to the Type System And Diagnostics track.

## Scope

- Implement `TY-010` as one narrow slice of work: Add an LSP skeleton that surfaces diagnostics, formatting, and symbol lookup
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

- `TY-009`

## Acceptance

- `TY-010` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
