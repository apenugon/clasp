# LG-007 Add Let Examples And Tests

## Goal

Add `let` examples and tests

## Why

The core language still needs enough control flow and ergonomics to support nontrivial application logic. This task belongs to the Core Language Surface track.

## Scope

- Implement `LG-007` as one narrow slice of work: Add `let` examples and tests
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/Syntax.hs`
- `src/Clasp/Parser.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`
- `examples/`

## Dependencies

- `LG-006`

## Acceptance

- `LG-007` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
