# SA-002 Add In-Memory Or File-Backed App State Primitives Suitable For The Dogfood App

## Goal

Add in-memory or file-backed app state primitives suitable for the dogfood app

## Why

The real test is whether agents can build and evolve a moderate product in Clasp rather than only patch compiler features. This task belongs to the SaaS Dogfooding track.

## Scope

- Implement `SA-002` as one narrow slice of work: Add in-memory or file-backed app state primitives suitable for the dogfood app
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `examples/`
- `runtime/`
- `benchmarks/`
- `docs/`
- `test/`

## Dependencies

- `SA-001`

## Acceptance

- `SA-002` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
