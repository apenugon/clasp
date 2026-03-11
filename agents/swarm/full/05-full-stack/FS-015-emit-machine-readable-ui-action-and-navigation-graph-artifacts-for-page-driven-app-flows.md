# FS-015 Emit Machine-Readable UI, Action, And Navigation Graph Artifacts For Page-Driven App Flows

## Goal

Emit machine-readable UI, action, and navigation graph artifacts for page-driven app flows

## Why

If `Clasp` owns pages, actions, forms, and navigation, then agents should not have to recover that structure from HTML or browser traces alone. UI and action graphs should be compiler-emitted artifacts. This task belongs to the Full-Stack Runtime And App Layer track.

## Scope

- Implement `FS-015` as one narrow slice of work: Emit machine-readable UI, action, and navigation graph artifacts for page-driven app flows
- Keep the first slice practical and benchmark-oriented: one page-flow graph with actions, navigation edges, and boundary identifiers is enough.
- Add or update regression coverage for one stable artifact shape and one changed flow that updates the graph correctly.
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

- `FS-014`

## Acceptance

- `FS-015` is implemented without breaking previously integrated tasks
- The compiler emits at least one machine-readable UI or action graph artifact that agents can query directly.
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
