# BM-028 Add Secret-Handling Benchmarks Proving Redaction, Policy-Gated Secret Access, And Root-Cause Blame Quality For Missing Or Misused Declared Secrets

## Goal

Add secret-handling benchmarks proving redaction, policy-gated secret access, and root-cause blame quality for missing or misused declared secrets

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-028` as one narrow slice of work: Add secret-handling benchmarks proving redaction, policy-gated secret access, and root-cause blame quality for missing or misused declared secrets
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/`
- `scripts/`

## Dependencies

- `BM-027`

## Acceptance

- `BM-028` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
