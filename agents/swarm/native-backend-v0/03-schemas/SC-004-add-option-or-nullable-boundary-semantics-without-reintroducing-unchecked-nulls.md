# SC-004 Add Option Or Nullable Boundary Semantics Without Reintroducing Unchecked Nulls

## Goal

Add `Option` or nullable boundary semantics without reintroducing unchecked nulls

## Why

Generated trust-boundary handling is one of the main reasons Clasp should outperform baseline stacks in agent-driven work. This task belongs to the Schemas And Trust Boundaries track.

## Scope

- Implement `SC-004` as one narrow slice of work: Add `Option` or nullable boundary semantics without reintroducing unchecked nulls
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/Checker.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `runtime/`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`
- `examples/`

## Dependencies

- `SC-003`

## Acceptance

- `SC-004` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
