# 0004 Comparison And Equality Operators

## Goal

Add a minimal operator surface for boolean conditions.

## Scope

- Add equality for `Int`, `Str`, and `Bool`
- Add integer comparison operators needed for ordinary branching
- Parse, typecheck, lower, and emit them
- Add regression tests and a small example that uses them with `if`

## Acceptance

- `bash scripts/verify-all.sh` passes

## Notes

Keep precedence and associativity rules simple. Do not introduce a large operator table in one task.
