# DB-007 Add Schema-Derived Table Declarations, Generated Database Constraints, And Semantic Storage Types That Reject Bare Primitives At Storage-Facing Boundaries

## Goal

Add schema-derived table declarations, generated database constraints, and semantic storage types that reject bare primitives at storage-facing boundaries

## Why

SQLite is the first persistence milestone after the app and language surfaces are already credible. This task belongs to the SQLite Storage track.

## Scope

- Implement `DB-007` as one narrow slice of work: Add schema-derived table declarations, generated database constraints, and semantic storage types that reject bare primitives at storage-facing boundaries
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites
- Require storage-facing schemas, table declarations, and generated constraints to use shared semantic/domain types instead of bare primitives
- Ensure generated storage metadata preserves the same semantic type identities used at route, schema, and application boundaries

## Likely Files

- `src/`
- `runtime/`
- `examples/`
- `benchmarks/`
- `docs/`
- `test/`

## Dependencies

- `DB-006`

## Acceptance

- `DB-007` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- Storage-facing declarations reject bare primitives where shared semantic/domain types are required
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
