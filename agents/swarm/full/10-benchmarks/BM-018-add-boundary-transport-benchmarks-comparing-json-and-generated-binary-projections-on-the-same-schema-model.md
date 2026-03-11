# BM-018 Add Boundary-Transport Benchmarks Comparing JSON And Generated Binary Projections On The Same Schema Model

## Goal

Add boundary-transport benchmarks comparing `JSON` and generated binary projections on the same schema model

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-018` as one narrow slice of work: Add boundary-transport benchmarks comparing `JSON` and generated binary projections on the same schema model
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `BM-017`

## Acceptance

- `BM-018` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
