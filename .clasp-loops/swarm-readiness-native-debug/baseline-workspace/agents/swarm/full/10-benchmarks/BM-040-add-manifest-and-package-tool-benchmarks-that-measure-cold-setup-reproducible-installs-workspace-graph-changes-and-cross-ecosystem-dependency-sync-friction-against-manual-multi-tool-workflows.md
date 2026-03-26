# BM-040 Add Manifest-And-Package-Tool Benchmarks That Measure Cold Setup, Reproducible Installs, Workspace Graph Changes, And Cross-Ecosystem Dependency Sync Friction Against Manual Multi-Tool Workflows

## Goal

Add manifest-and-package-tool benchmarks that measure cold setup, reproducible installs, workspace graph changes, and cross-ecosystem dependency sync friction against manual multi-tool workflows

## Why

The project needs a benchmark story that is reproducible, public, and grounded in real agent harness outcomes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-040` as one narrow slice of work: Add manifest-and-package-tool benchmarks that measure cold setup, reproducible installs, workspace graph changes, and cross-ecosystem dependency sync friction against manual multi-tool workflows
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

- `TY-028`
- `FS-025`

## Acceptance

- `BM-040` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
