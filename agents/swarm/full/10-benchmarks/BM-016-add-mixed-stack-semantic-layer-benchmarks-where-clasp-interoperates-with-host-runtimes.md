# BM-016 Add Mixed-Stack Semantic-Layer Benchmarks Where Clasp Interoperates With Host Runtimes

## Goal

Add mixed-stack semantic-layer benchmarks where `Clasp` interoperates with host runtimes

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-016` as one narrow slice of work: Add mixed-stack semantic-layer benchmarks where `Clasp` interoperates with host runtimes
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `BM-015`

## Acceptance

- `BM-016` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
