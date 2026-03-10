# 0004 Comparison And Equality Operators

## Goal

Add a minimal operator surface for boolean conditions.

## Scope

- Add equality for `Int`, `Str`, and `Bool`
- Add integer comparison operators needed for ordinary branching
- Parse, typecheck, lower, and emit them
- Add regression tests and a small example that uses them with `if`

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

Keep precedence and associativity rules simple. Do not introduce a large operator table in one task.
