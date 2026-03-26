# DB-010 Add Policy-Aware Queries, Mutations, And Proof-Gated Row Or Field Access For Protected Storage Models Without Falling Back To Bare Primitive Storage-Facing Types

## Goal

Add policy-aware queries, mutations, and proof-gated row or field access for protected storage models without falling back to bare primitive storage-facing types

## Why

SQLite is the first persistence milestone after the app and language surfaces are already credible. This task belongs to the SQLite Storage track.

## Scope

- Implement `DB-010` as one narrow slice of work: Add policy-aware queries, mutations, and proof-gated row or field access for protected storage models without falling back to bare primitive storage-facing types
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites
- Require protected row and field access to preserve policy proofs and shared semantic types end to end instead of degrading to primitive storage values
- Ensure policy-aware query and mutation surfaces do not fall back to bare primitives on storage-facing declarations, row contracts, or protected projections

## Likely Files

- `src/`
- `runtime/`
- `examples/`
- `benchmarks/`
- `docs/`
- `test/`

## Dependencies

- `DB-009`

## Acceptance

- `DB-010` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- Policy-aware storage access preserves proof-gated semantic types without primitive fallback at protected row or field boundaries
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
