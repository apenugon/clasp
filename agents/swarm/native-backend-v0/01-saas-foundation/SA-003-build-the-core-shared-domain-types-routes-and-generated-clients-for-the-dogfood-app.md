# SA-003 Build The Core Shared Domain Types, Routes, And Generated Clients For The Dogfood App

## Goal

Build the core shared domain types, routes, and generated clients for the dogfood app

## Why

The real test is whether agents can build and evolve a moderate product in Clasp rather than only patch compiler features. This task belongs to the SaaS Dogfooding track.

## Scope

- Implement `SA-003` as one narrow slice of work: Build the core shared domain types, routes, and generated clients for the dogfood app
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

- `SA-002`

## Acceptance

- `SA-003` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
