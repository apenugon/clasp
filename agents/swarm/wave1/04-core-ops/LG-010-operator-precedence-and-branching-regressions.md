# LG-010 Operator Precedence And Branching Regressions

## Goal

Lock down precedence, associativity, and checker behavior for the first operator set.

## Why

Adding operators without regression coverage is a good way to make parser behavior unstable for both humans and agents.

## Scope

- Add parser precedence coverage for the current operators
- Add checker regressions for invalid operator combinations
- Add one example that combines operators with boolean branching once supported

## Likely Files

- `src/Clasp/Parser.hs`
- `test/Main.hs`
- `examples/`
- `docs/clasp-spec-v0.md`

## Dependencies

- `LG-009`

## Acceptance

- Operator precedence is covered by tests
- Regression cases are explicit
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
