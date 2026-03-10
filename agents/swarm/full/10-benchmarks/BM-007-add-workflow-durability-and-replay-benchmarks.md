# BM-007 Add Workflow Durability And Replay Benchmarks

## Goal

Add workflow durability and replay benchmarks

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-007` as one narrow slice of work: Add workflow durability and replay benchmarks
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `WF-010`

## Acceptance

- `BM-007` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
