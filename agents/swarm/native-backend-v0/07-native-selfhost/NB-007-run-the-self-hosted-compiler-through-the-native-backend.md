# NB-007 Run The Self-Hosted Compiler Through The Native Backend

## Goal

Run the self-hosted compiler through the native backend

## Why

Clasp needs a path beyond JavaScript for backend and compiler workloads once the hosted path is proven. This task belongs to the Native Backend And Bytecode track.

## Scope

- Implement `NB-007` as one narrow slice of work: Run the self-hosted compiler through the native backend
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/`
- `runtime/`
- `docs/`
- `test/`
- `benchmarks/`

## Dependencies

- `NB-006`

## Acceptance

- `NB-007` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
