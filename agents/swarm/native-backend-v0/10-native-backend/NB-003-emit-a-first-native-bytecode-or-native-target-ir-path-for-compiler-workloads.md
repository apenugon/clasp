# NB-003 Emit A First Native Bytecode Or Native-Target IR Path For Compiler Workloads

## Goal

Emit a first native bytecode or native-target IR path for compiler workloads

## Why

Clasp needs a path beyond JavaScript for backend and compiler workloads once the hosted path is proven. This task belongs to the Native Backend And Bytecode track.

## Scope

- Implement `NB-003` as one narrow slice of work: Emit a first native bytecode or native-target IR path for compiler workloads
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

- `NB-002`

## Acceptance

- `NB-003` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
