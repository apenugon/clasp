# LG-001 List Type Syntax And Parser

## Goal

Add list types and list literal parsing to Clasp.

## Why

Lists are the next basic data structure needed for real full-stack application logic.

## Scope

- Add one list type form to the AST
- Add one list literal form to the AST
- Parse list types
- Parse list literals
- Keep the syntax compact and canonical

## Likely Files

- `src/Clasp/Syntax.hs`
- `src/Clasp/Parser.hs`
- `docs/clasp-spec-v0.md`
- `test/Main.hs`

## Dependencies

- None

## Acceptance

- List types parse successfully
- List literals parse successfully
- Parser tests cover the new syntax
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
