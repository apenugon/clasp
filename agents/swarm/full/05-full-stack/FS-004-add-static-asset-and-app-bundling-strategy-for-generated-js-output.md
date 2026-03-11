# FS-004 Add Static Asset, Head, And Style-Bundle Strategy For Generated JS Output

## Goal

Add static asset, head, and style-bundle strategy for generated JS output

## Why

Clasp needs one shared app surface that spans backend, frontend, workers, and eventually mobile. Asset delivery, page head composition, and style bundles should be part of that platform surface rather than left entirely to ad hoc host setup. This task belongs to the Full-Stack Runtime And App Layer track.

## Scope

- Implement `FS-004` as one narrow slice of work: add static asset, head, and style-bundle strategy for generated JS output.
- Define enough structure that compiler-owned pages and future compiler-owned styling can reference emitted assets without falling back to arbitrary string conventions.
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

- `FS-003`

## Acceptance

- `FS-004` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
