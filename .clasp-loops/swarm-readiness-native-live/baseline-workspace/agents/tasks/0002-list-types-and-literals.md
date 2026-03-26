# 0002 List Types And Literals

## Goal

Add homogeneous list support to Clasp.

## Scope

- Add a list type form to the language
- Parse list literals
- Typecheck list literals and list-typed declarations
- Lower and emit lists to JavaScript arrays
- Extend JSON boundary support for lists of supported codec types
- Add examples and tests

## Likely Files

- `src/Clasp/Syntax.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Parser.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`
- `examples/records.clasp`

## Acceptance

- `bash scripts/verify-all.sh` passes

## Notes

Keep the syntax small and canonical. Favor one obvious representation over multiple aliases.
Use one homogeneous list type form and one list-literal form. Avoid broad refactors outside the list pipeline.
