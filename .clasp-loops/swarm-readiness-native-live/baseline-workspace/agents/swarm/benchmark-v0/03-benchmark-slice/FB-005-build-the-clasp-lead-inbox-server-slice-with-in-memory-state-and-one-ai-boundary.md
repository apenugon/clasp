# FB-005 Build The Clasp Lead-Inbox Server Slice With In-Memory State And One AI Boundary

## Goal

Build the Clasp lead-inbox server slice with in-memory state and one AI boundary.

## Why

The first credible benchmark needs a real app slice with product state, not only a stateless summary endpoint.

## Scope

- Add a small lead-inbox server slice in `Clasp` using in-memory state and the existing AI-shaped summary/prioritization boundary.
- Keep the first version intentionally small: intake, storage, list/inbox retrieval, and one validated AI-shaped summary path are enough.
- Reuse generated route metadata and generated validation rather than hand-coded glue.
- Add or update regression coverage for the server slice and one end-to-end happy path.
- Avoid database work, auth, or workflow durability in this task.

## Likely Files

- `examples/`
- `runtime/`
- `src/Clasp/Emit/JavaScript.hs`
- `benchmarks/`
- `test/Main.hs`

## Dependencies

- `FB-001`
- `FB-004`

## Acceptance

- A benchmark-oriented Clasp lead-inbox server slice exists with in-memory state and one AI-shaped boundary.
- Shared contracts and generated validation remain the main way data crosses trust boundaries.
- Tests or regressions cover intake, storage, inbox retrieval, and one invalid-boundary path.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
