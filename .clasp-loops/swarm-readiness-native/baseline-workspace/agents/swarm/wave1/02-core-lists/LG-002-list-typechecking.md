# LG-002 List Typechecking

## Goal

Typecheck homogeneous lists in Clasp.

## Why

Parsed list syntax is not useful until the checker can validate element homogeneity and list-typed declarations.

## Scope

- Add list typing rules to the checker
- Require homogeneous element types
- Support empty-list checking only if a type annotation or surrounding context makes it sound
- Add focused checker tests

## Likely Files

- `src/Clasp/Checker.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Syntax.hs`
- `test/Main.hs`

## Dependencies

- `LG-001`

## Acceptance

- Homogeneous list literals typecheck
- Heterogeneous lists fail with a structured diagnostic
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
