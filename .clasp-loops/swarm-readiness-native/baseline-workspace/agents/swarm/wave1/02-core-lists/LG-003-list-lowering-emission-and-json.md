# LG-003 List Lowering Emission And JSON

## Goal

Lower lists to the backend IR, emit them as JavaScript arrays, and support them at JSON boundaries.

## Why

Lists must work end to end, not just in the parser and checker.

## Scope

- Add list forms to the typed core and lowered IR if needed
- Emit lists to JavaScript arrays
- Extend generated JSON codecs for lists of supported boundary types
- Add lowering, emitter, and boundary tests

## Likely Files

- `src/Clasp/Core.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `src/Clasp/Checker.hs`
- `test/Main.hs`

## Dependencies

- `LG-002`

## Acceptance

- Checked list programs compile to runnable JavaScript arrays
- Supported list boundary types encode and decode correctly
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
