# SH-012 Switch Ordinary Check, Compile, Explain, Manifest, And Package-Tool Flows To The Clasp Compiler By Default While Retaining The Haskell Bootstrap Fallback And Explicit Compatibility Checks

## Goal

Switch ordinary `check`, `compile`, `explain`, manifest, and package-tool flows to the Clasp compiler by default while retaining the Haskell bootstrap fallback and explicit compatibility checks

## Why

Clasp should eventually be able to carry its own compiler once the language and runtime are mature enough. This task belongs to the Self-Hosting track.

## Scope

- Implement `SH-012` as one narrow slice of work: Switch ordinary `check`, `compile`, `explain`, manifest, and package-tool flows to the Clasp compiler by default while retaining the Haskell bootstrap fallback and explicit compatibility checks
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/`
- `examples/`
- `docs/`
- `test/`
- `benchmarks/`

## Dependencies

- `SH-011`

## Acceptance

- `SH-012` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
