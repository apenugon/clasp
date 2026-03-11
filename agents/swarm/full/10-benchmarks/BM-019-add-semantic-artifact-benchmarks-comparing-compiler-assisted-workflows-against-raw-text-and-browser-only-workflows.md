# BM-019 Add Semantic-Artifact Benchmarks Comparing Compiler-Assisted Workflows Against Raw Text And Browser-Only Workflows

## Goal

Add semantic-artifact benchmarks comparing compiler-assisted workflows against raw text and browser-only workflows

## Why

If `Clasp` emits context graphs, UI/action graphs, structured diagnostics, and semantic edit operations, then the benchmark program should measure whether those artifacts actually reduce agent work relative to raw text search and browser-only inspection. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-019` as one narrow slice of work: Add semantic-artifact benchmarks comparing compiler-assisted workflows against raw text and browser-only workflows
- Compare at least one task in two modes: raw text/browser workflow versus compiler-artifact-assisted workflow.
- Keep the task suite fair by holding model, harness, budget, repo, and acceptance criteria constant.
- Add or update regression coverage for the new behavior
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
- The benchmark suite includes at least one reproducible comparison between semantic-artifact-assisted and raw text/browser-only workflows.
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
