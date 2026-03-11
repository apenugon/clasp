# DB-008 Add Typed Transactions, Isolation Boundaries, And Mutation Semantics For Storage Effects

## Goal

Add typed transactions, isolation boundaries, and mutation semantics for storage effects

## Why

Storage correctness is not just row shape correctness. Real apps also need typed mutation boundaries, transaction structure, and explicit isolation assumptions. This task belongs to the SQLite Storage track.

## Scope

- Implement `DB-008` as one narrow slice of work: add typed transactions, isolation boundaries, and mutation semantics for storage effects.
- Keep the first slice small and benchmark-oriented: one transaction form, one mutation path, and one invalid cross-boundary use are enough.
- Tie the surface into effect and capability annotations rather than treating transactions as opaque runtime helpers.
- Add or update regression coverage for one successful transaction path and one rejected misuse.
- Update docs or examples only where the new surface changes visible behavior.
- Avoid turning this task into full distributed transaction support or broad concurrency verification.

## Likely Files

- `src/`
- `runtime/`
- `examples/`
- `benchmarks/`
- `docs/`
- `test/`

## Dependencies

- `DB-007`
- `TY-011`

## Acceptance

- `Clasp` can express at least one typed transaction or mutation boundary for storage effects.
- The compiler or generated runtime rejects at least one misuse across the transaction boundary.
- Tests or regressions cover one successful transaction path and one rejected misuse.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
