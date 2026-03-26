# BM-038 Add Parallel-Runtime Benchmarks Proving Mailbox Safety, Supervision Correctness, Hot-Upgrade Safety, And Multicore Scalability For Isolated Workflow Or Process Execution

## Goal

Add parallel-runtime benchmarks proving mailbox safety, supervision correctness, hot-upgrade safety, and multicore scalability for isolated workflow or process execution

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-038` as one narrow slice of work: Add parallel-runtime benchmarks proving mailbox safety, supervision correctness, hot-upgrade safety, and multicore scalability for isolated workflow or process execution
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

- `WF-019`

## Acceptance

- `BM-038` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
