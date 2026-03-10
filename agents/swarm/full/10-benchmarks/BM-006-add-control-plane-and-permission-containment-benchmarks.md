# BM-006 Add Control-Plane And Permission-Containment Benchmarks

## Goal

Add control-plane and permission-containment benchmarks

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-006` as one narrow slice of work: Add control-plane and permission-containment benchmarks
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `CP-009`

## Acceptance

- `BM-006` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
