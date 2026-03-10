# LG-008 Equality Operators

## Goal

Add equality operators for `Int`, `Str`, and `Bool`.

## Why

Simple branching and application logic need equality before more expressive control flow becomes practical.

## Scope

- Add equality operator syntax
- Typecheck equality for `Int`, `Str`, and `Bool`
- Lower and emit equality
- Add focused tests

## Likely Files

- `src/Clasp/Syntax.hs`
- `src/Clasp/Parser.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `test/Main.hs`

## Dependencies

- None

## Acceptance

- Equality expressions parse, typecheck, and emit correctly
- Unsupported equality cases fail with a structured diagnostic
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
