# LG-006 Let Typechecking And Lowering

## Goal

Typecheck local `let` bindings and lower them cleanly to JavaScript.

## Why

The parser slice alone does not make `let` usable in real code.

## Scope

- Typecheck local bindings with inference where sound
- Lower `let` expressions into the typed core and lowered IR
- Emit clean JavaScript for the chosen representation
- Add checker, lowering, and emitter tests

## Likely Files

- `src/Clasp/Checker.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `test/Main.hs`

## Dependencies

- `LG-005`

## Acceptance

- `let` expressions typecheck
- Generated JavaScript is runnable
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
