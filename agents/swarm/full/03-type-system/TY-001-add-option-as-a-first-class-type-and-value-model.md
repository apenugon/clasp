# TY-001 Add Option As A First-Class Type And Value Model

## Goal

Add `Option` as a first-class type and value model

## Why

Clasp needs stronger typing and more useful diagnostics than mainstream baseline stacks if the language thesis is going to hold up. This task belongs to the Type System And Diagnostics track.

## Scope

- Implement `TY-001` as one narrow slice of work: Add `Option` as a first-class type and value model
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

- `LG-019`

## Acceptance

- `TY-001` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
