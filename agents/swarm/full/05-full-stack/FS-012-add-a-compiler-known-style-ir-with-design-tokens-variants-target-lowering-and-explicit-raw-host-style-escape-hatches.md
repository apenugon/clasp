# FS-012 Add A Compiler-Known Style IR With Design Tokens, Variants, Target Lowering, And Explicit Raw Host-Style Escape Hatches

## Goal

Add a compiler-known style IR with design tokens, variants, target lowering, and explicit raw host-style escape hatches

## Why

Clasp needs one shared app surface that spans backend, frontend, workers, and eventually mobile. This task belongs to the Full-Stack Runtime And App Layer track.

## Scope

- Implement `FS-012` as one narrow slice of work: Add a compiler-known style IR with design tokens, variants, target lowering, and explicit raw host-style escape hatches
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

- `FS-011`

## Acceptance

- `FS-012` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
