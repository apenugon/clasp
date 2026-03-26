# LG-009 Integer Comparison Operators

## Goal

Add the first integer comparison operators needed for direct branching.

## Why

Clasp needs a minimal operator set for ordinary application conditions.

## Scope

- Add integer comparison operator syntax
- Typecheck integer comparisons
- Lower and emit them
- Add focused tests

## Likely Files

- `src/Clasp/Syntax.hs`
- `src/Clasp/Parser.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `test/Main.hs`

## Dependencies

- `LG-008`

## Acceptance

- Integer comparison expressions parse, typecheck, and emit correctly
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
