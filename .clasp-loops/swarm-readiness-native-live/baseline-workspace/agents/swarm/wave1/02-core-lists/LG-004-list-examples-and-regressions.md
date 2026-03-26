# LG-004 List Examples And Regressions

## Goal

Add list examples and regression coverage once the list pipeline lands.

## Why

The earlier list task failed partly because the feature was too broad. This task is only for examples and regressions after the implementation slices are in place.

## Scope

- Add at least one example program using lists
- Add regression tests around the accepted list shape
- Update the v0 spec examples if behavior changed

## Likely Files

- `examples/`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`

## Dependencies

- `LG-003`

## Acceptance

- Example programs demonstrate list usage
- Regression tests cover representative list cases
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
