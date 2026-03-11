# TY-011 Add Typed Effect And Capability Annotations Shared Across Functions, Tools, And Workflows

## Goal

Add typed effect and capability annotations shared across functions, tools, and workflows

## Why

Clasp needs stronger typing and more useful diagnostics than mainstream baseline stacks if the language thesis is going to hold up. This task belongs to the Type System And Diagnostics track.

## Scope

- Implement `TY-011` as one narrow slice of work: Add typed effect and capability annotations shared across functions, tools, and workflows
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

- `TY-010`

## Acceptance

- `TY-011` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
