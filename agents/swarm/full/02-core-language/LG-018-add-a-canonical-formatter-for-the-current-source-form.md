# LG-018 Add A Canonical Formatter For The Current Source Form

## Goal

Add a canonical formatter for the current source form

## Why

The core language still needs enough control flow and ergonomics to support nontrivial application logic. This task belongs to the Core Language Surface track.

## Scope

- Implement `LG-018` as one narrow slice of work: Add a canonical formatter for the current source form
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

- `LG-017`

## Acceptance

- `LG-018` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
