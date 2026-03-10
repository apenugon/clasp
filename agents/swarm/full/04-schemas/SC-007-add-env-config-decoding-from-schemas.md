# SC-007 Add Env/Config Decoding From Schemas

## Goal

Add env/config decoding from schemas

## Why

Generated trust-boundary handling is one of the main reasons Clasp should outperform baseline stacks in agent-driven work. This task belongs to the Schemas And Trust Boundaries track.

## Scope

- Implement `SC-007` as one narrow slice of work: Add env/config decoding from schemas
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

- `SC-006`

## Acceptance

- `SC-007` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
