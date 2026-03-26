# TY-014 Add Semantic Edit And Refactor Operations Over Compiler-Known Declarations And Schemas

## Goal

Add semantic edit and refactor operations over compiler-known declarations and schemas

## Why

The end-state benchmark win is not that agents grep faster. It is that they can ask the compiler to apply bounded semantic changes over shared declarations and affected surfaces. This task is the first direct step toward that.

## Scope

- Implement `TY-014` as one focused slice of work on semantic edit/refactor operations
- Prefer the smallest useful benchmark-oriented first pass over a broad general-purpose refactor engine
- Add or update regression coverage for the new behavior
- Update docs only where visible machine-facing behavior changes
- Avoid unrelated compiler redesign

## Likely Files

- `src/Clasp/Compiler.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Checker.hs`
- `test/Main.hs`
- `docs/`

## Dependencies

- `TY-015`
- `CP-013`
- `FS-015`

## Acceptance

- `TY-014` is implemented without breaking the benchmark slice or previously integrated tasks
- The compiler exposes at least one benchmark-relevant semantic edit or refactor surface over compiler-known declarations or schemas
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
