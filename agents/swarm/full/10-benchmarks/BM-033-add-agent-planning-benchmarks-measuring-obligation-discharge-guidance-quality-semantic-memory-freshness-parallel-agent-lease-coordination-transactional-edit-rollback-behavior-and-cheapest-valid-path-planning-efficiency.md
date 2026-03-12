# BM-033 Add Agent-Planning Benchmarks Measuring Obligation-Discharge Guidance Quality, Semantic-Memory Freshness, Parallel-Agent Lease Coordination, Transactional-Edit Rollback Behavior, And Cheapest-Valid-Path Planning Efficiency

## Goal

Add agent-planning benchmarks measuring obligation-discharge guidance quality, semantic-memory freshness, parallel-agent lease coordination, transactional-edit rollback behavior, and cheapest-valid-path planning efficiency

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-033` as one narrow slice of work: Add agent-planning benchmarks measuring obligation-discharge guidance quality, semantic-memory freshness, parallel-agent lease coordination, transactional-edit rollback behavior, and cheapest-valid-path planning efficiency
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

- `BM-032`

## Acceptance

- `BM-033` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
