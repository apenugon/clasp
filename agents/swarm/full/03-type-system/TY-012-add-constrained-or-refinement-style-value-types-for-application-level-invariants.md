# TY-012 Add Constrained Or Refinement-Style Value Types For Application-Level Invariants

## Goal

Add constrained or refinement-style value types for application-level invariants

## Why

Shared schemas catch shape mismatches, but many real app bugs come from invalid values that still fit the outer shape. `Clasp` needs a compiler-known way to model application invariants such as non-empty text, bounded numbers, or validated IDs. This task belongs to the Type System And Diagnostics track.

## Scope

- Implement `TY-012` as one narrow slice of work: add a first compiler-known constrained value model for application invariants.
- Keep the first slice small and benchmark-oriented: one or two predicate forms and one narrowing path are enough.
- Make the surface usable from schemas, routes, forms, and storage-facing types rather than as an isolated type-system toy.
- Preserve a path for compile-time reasoning where facts are available and generated runtime validation where values cross trust boundaries.
- Add or update regression coverage for typechecking, narrowing, and one boundary-validation path.
- Update docs or examples only where the new surface changes visible behavior.
- Avoid turning this task into a full theorem prover or large proof language.

## Likely Files

- `src/Clasp/Syntax.hs`
- `src/Clasp/Parser.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`

## Dependencies

- `TY-003`
- `SC-001`

## Acceptance

- `Clasp` can express at least one constrained or refinement-style value type.
- The checker can reject obvious misuse and preserve the constrained type through at least one safe narrowing path.
- Generated runtime validation exists where external data enters a constrained type.
- Tests or regressions cover typing, narrowing, and one trust-boundary validation path.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
