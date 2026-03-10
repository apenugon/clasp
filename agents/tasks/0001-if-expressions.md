# 0001 If Expressions

## Goal

Add first-class `if` expressions so Clasp can express direct boolean branching without encoding everything as function calls or ADT-only control flow.

## Why

This moves the language toward the more mainstream, more imperative-adjacent surface discussed in the design docs while staying compatible with the typed core architecture.

## Scope

- Parse `if <cond> then <when_true> else <when_false>`
- Represent `if` in the syntax tree and typed core
- Typecheck the condition as `Bool`
- Require both branches to resolve to the same type
- Lower and emit `if` to JavaScript
- Add at least one example program using `if`
- Add parser, checker, lowering, and emitter tests

## Likely Files

- `src/Clasp/Syntax.hs`
- `src/Clasp/Parser.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`

## Acceptance

- `cabal test` passes
- `claspc check` succeeds on the new example
- The JS emitter produces runnable output for the new example

## Verification

Run:

```sh
bash scripts/verify-all.sh
```
