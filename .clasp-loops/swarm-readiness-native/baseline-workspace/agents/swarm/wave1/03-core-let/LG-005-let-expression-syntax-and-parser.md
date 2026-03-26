# LG-005 Let Expression Syntax And Parser

## Goal

Add local `let` expressions to the AST and parser.

## Why

Local bindings are a basic ergonomics improvement and a stepping stone toward a more imperative or hybrid surface.

## Scope

- Add one `let` expression form
- Parse local bindings
- Keep the syntax small and canonical
- Add parser tests

## Likely Files

- `src/Clasp/Syntax.hs`
- `src/Clasp/Parser.hs`
- `docs/clasp-spec-v0.md`
- `test/Main.hs`

## Dependencies

- None

## Acceptance

- `let` expressions parse successfully
- Parser tests cover representative cases
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
