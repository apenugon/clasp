# BM-031 Add Agent-Efficiency Benchmarks Measuring Minimal-Context-Pack Quality, Affected-Surface Verification Selectivity, And Staged-Check Latency Against Full-Repo Baselines

## Goal

Add agent-efficiency benchmarks measuring minimal-context-pack quality, affected-surface verification selectivity, and staged-check latency against full-repo baselines

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-031` as one narrow slice of work: Add agent-efficiency benchmarks measuring minimal-context-pack quality, affected-surface verification selectivity, and staged-check latency against full-repo baselines
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

- `BM-030`

## Acceptance

- `BM-031` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
