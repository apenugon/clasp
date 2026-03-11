# TY-013 Add Compiler-Known Typestate Or State-Machine Declarations For UI, Workflow, And Domain Transitions

## Goal

Add compiler-known typestate or state-machine declarations for UI, workflow, and domain transitions

## Why

Many important full-stack bugs are illegal transitions, not type-shape mismatches. `Clasp` should be able to model and check transitions across pages, workflows, and business objects explicitly. This task belongs to the Type System And Diagnostics track.

## Scope

- Implement `TY-013` as one narrow slice of work: add a compiler-known typestate or state-machine declaration surface.
- Keep the first slice small and benchmark-oriented: a finite set of states, typed transitions, and one illegal-transition check are enough.
- Make the surface reusable by full-stack page flows, business-object lifecycles, and workflow declarations rather than hard-coding it to one domain.
- Add or update regression coverage for one valid transition path and one rejected transition.
- Update docs or examples only where the new surface changes visible behavior.
- Avoid turning this task into a full temporal-logic or model-checking system.

## Likely Files

- `src/Clasp/Syntax.hs`
- `src/Clasp/Parser.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Lower.hs`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`

## Dependencies

- `TY-011`

## Acceptance

- `Clasp` can express a small compiler-known typestate or state-machine model.
- The checker can reject at least one illegal transition in ordinary code.
- Tests or regressions cover one valid transition path and one rejected transition.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
