# DB-008 Add Typed Transactions, Isolation Boundaries, And Mutation Semantics For Storage Effects While Preserving Semantic Storage Types Rather Than Raw Primitive Rows

## Goal

Add typed transactions, isolation boundaries, and mutation semantics for storage effects while preserving semantic storage types rather than raw primitive rows

## Why

SQLite is the first persistence milestone after the app and language surfaces are already credible. This task belongs to the SQLite Storage track.

## Scope

- Implement `DB-008` as one narrow slice of work: Add typed transactions, isolation boundaries, and mutation semantics for storage effects while preserving semantic storage types rather than raw primitive rows
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites
- Keep transaction inputs, mutation outputs, and row-mapping surfaces in shared semantic types rather than exposing raw primitive rows
- Reject transaction or mutation APIs that reintroduce bare primitive storage-facing types where shared semantic types already exist

## Likely Files

- `src/`
- `runtime/`
- `examples/`
- `benchmarks/`
- `docs/`
- `test/`

## Dependencies

- `DB-007`

## Acceptance

- `DB-008` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- Transaction and mutation surfaces preserve semantic storage types instead of raw primitive rows
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
