# FS-011 Define A Stable Host-Interop Contract For JS, Native, Storage, And Provider-Backed Runtimes

## Goal

Define a stable host-interop contract for `JS`, native, storage, and provider-backed runtimes.

## Why

Clasp only reaches broad adoption if it can become the primary semantic layer of a real system without forcing every substrate to be rewritten first. This task belongs to the Full-Stack Runtime And App Layer track.

## Scope

- Implement `FS-011` as one narrow slice of work: define a stable host-interop contract for `JS`, native, storage, and provider-backed runtimes.
- Focus on the compiler-visible boundary and generated contract shape rather than on supporting every host runtime in one task.
- Reuse or refine the existing foreign/runtime story instead of creating multiple unrelated interop mechanisms.
- Add or update regression coverage for generated interop metadata, typed host-boundary checking, and one representative runtime path.
- Update docs or examples only where the new surface changes visible behavior.
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/Syntax.hs`
- `src/Clasp/Parser.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `runtime/`
- `examples/`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`
- `docs/clasp-roadmap.md`

## Dependencies

- `FS-005`

## Acceptance

- One stable, typed interop contract exists for foreign host boundaries instead of ad hoc per-runtime conventions.
- The compiler or generated artifacts preserve enough metadata for later native, storage, and provider-backed runtimes to consume the same contract shape.
- Tests or regressions cover one representative interop path and the generated boundary metadata.
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
