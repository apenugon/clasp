# NB-009 Add Native Support For Compiler-Owned Binary Boundary Codecs And Efficient Service Transport

## Goal

Add native support for compiler-owned binary boundary codecs and efficient service transport

## Why

Clasp needs a path beyond JavaScript for backend and compiler workloads once the hosted path is proven. This task belongs to the Native Backend And Bytecode track.

## Scope

- Implement `NB-009` as one narrow slice of work: Add native support for compiler-owned binary boundary codecs and efficient service transport
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

- `NB-008`

## Acceptance

- `NB-009` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
