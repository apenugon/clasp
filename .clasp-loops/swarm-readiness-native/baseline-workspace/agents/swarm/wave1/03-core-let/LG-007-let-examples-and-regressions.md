# LG-007 Let Examples And Regressions

## Goal

Add example usage and regression coverage for local `let` expressions.

## Why

This isolates examples and regression updates from the parser/checker implementation slices.

## Scope

- Add one or more example programs using `let`
- Add regression tests for the accepted `let` behavior
- Update the spec if the new surface needs examples

## Likely Files

- `examples/`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`

## Dependencies

- `LG-006`

## Acceptance

- Examples show idiomatic `let` usage
- Regression coverage exists
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
