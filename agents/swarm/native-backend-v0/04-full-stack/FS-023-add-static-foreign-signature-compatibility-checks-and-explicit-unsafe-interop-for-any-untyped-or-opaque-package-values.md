# FS-023 Add Static Foreign-Signature Compatibility Checks And Explicit Unsafe Interop For Any, Untyped, Or Opaque Package Values

## Goal

Add static foreign-signature compatibility checks and explicit unsafe interop for `any`, untyped, or opaque package values

## Why

Clasp needs one shared app surface that spans backend, frontend, workers, and eventually mobile. This task belongs to the Full-Stack Runtime And App Layer track.

## Scope

- Implement `FS-023` as one narrow slice of work: Add static foreign-signature compatibility checks and explicit unsafe interop for `any`, untyped, or opaque package values
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/Emit/JavaScript.hs`
- `runtime/bun/`
- `examples/`
- `benchmarks/`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`

## Dependencies

- `FS-022`

## Acceptance

- `FS-023` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
