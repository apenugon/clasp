# BM-019 Add Semantic-Artifact Benchmarks Comparing Compiler-Assisted Workflows Against Raw Text And Browser-Only Workflows

## Goal

Add semantic-artifact benchmarks comparing compiler-assisted workflows against raw text and browser-only workflows

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-019` as one narrow slice of work: Add semantic-artifact benchmarks comparing compiler-assisted workflows against raw text and browser-only workflows
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

- `BM-018`

## Acceptance

- `BM-019` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
