# BM-020 Add Authorization And Data-Access Benchmarks Proving Protected Reads, Writes, And Field Disclosures Require Policy Proofs

## Goal

Add authorization and data-access benchmarks proving protected reads, writes, and field disclosures require policy proofs

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-020` as one narrow slice of work: Add authorization and data-access benchmarks proving protected reads, writes, and field disclosures require policy proofs
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `BM-019`

## Acceptance

- `BM-020` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
