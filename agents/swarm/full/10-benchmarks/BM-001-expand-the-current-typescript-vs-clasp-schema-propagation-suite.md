# BM-001 Expand The Current TypeScript Vs Clasp Schema-Propagation Suite

## Goal

Expand the current TypeScript vs Clasp schema-propagation suite

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-001` as one narrow slice of work: Expand the current TypeScript vs Clasp schema-propagation suite
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `FS-005`

## Acceptance

- `BM-001` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
