# BM-027 Add An Oracle Benchmark Mode That Names The Exact Analogous Edit Surfaces So Language And Edit-Model Effects Can Be Measured Separately From Repo Discovery

## Goal

Add an `Oracle` benchmark mode that names the exact analogous edit surfaces so language and edit-model effects can be measured separately from repo discovery

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-027` as one narrow slice of work: Add an `Oracle` benchmark mode that names the exact analogous edit surfaces so language and edit-model effects can be measured separately from repo discovery
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

- `BM-026`

## Acceptance

- `BM-027` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
