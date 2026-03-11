# SC-014 Add Invariant, Precondition, And Postcondition Declarations Tied To Schemas And State Transitions

## Goal

Add invariant, precondition, and postcondition declarations tied to schemas and state transitions

## Why

Full-stack correctness needs more than structural schemas. Apps also need shared declarations for facts such as allowed transitions, required field relationships, and mutation guarantees. This task belongs to the Schemas And Trust Boundaries track.

## Scope

- Implement `SC-014` as one narrow slice of work: add invariant, precondition, and postcondition declarations that attach to schemas or state transitions.
- Keep the first slice small and benchmark-oriented: one declaration form and one enforcement path are enough.
- Reuse the same declarations for compile-time checking where possible and generated runtime validation where values or transitions cross trust boundaries.
- Add or update regression coverage for one satisfied invariant and one rejected invariant or transition path.
- Update docs or examples only where the new surface changes visible behavior.
- Avoid turning this task into a general proof assistant or large contract DSL.

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

- `SC-001`
- `TY-012`
- `TY-013`

## Acceptance

- `Clasp` can declare at least one invariant, precondition, or postcondition against a schema or state transition.
- The compiler uses that declaration for static checking where facts are known and generated runtime checks where boundaries remain open.
- Tests or regressions cover one accepted path and one rejected path.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
