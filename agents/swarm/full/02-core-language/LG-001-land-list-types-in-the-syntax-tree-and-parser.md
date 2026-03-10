# LG-001 Land List Types In The Syntax Tree And Parser

## Goal

Land list types in the syntax tree and parser

## Why

The core language still needs enough control flow and ergonomics to support nontrivial application logic. This task belongs to the Core Language Surface track.

## Scope

- Implement `LG-001` as one narrow slice of work: Land list types in the syntax tree and parser
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

- None

## Acceptance

- `LG-001` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
