# LG-019 Add Clasp Explain Or Equivalent Expanded Human-Readable Rendering

## Goal

Add `clasp explain` or equivalent expanded human-readable rendering

## Why

The core language still needs enough control flow and ergonomics to support nontrivial application logic. This task belongs to the Core Language Surface track.

## Scope

- Implement `LG-019` as one narrow slice of work: Add `clasp explain` or equivalent expanded human-readable rendering
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

- `LG-018`

## Acceptance

- `LG-019` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
