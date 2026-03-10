# 0003 Let Expressions

## Goal

Add local `let` bindings inside expressions.

## Scope

- Parse local `let` expressions
- Typecheck local bindings with inference where possible
- Lower and emit them cleanly to JavaScript
- Add focused tests and one example

## Likely Files

- `src/Clasp/Syntax.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Parser.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`
- `examples/`

## Acceptance

- `bash scripts/verify-all.sh` passes

## Notes

This is meant to improve ergonomics for nontrivial app logic without abandoning the typed core.
