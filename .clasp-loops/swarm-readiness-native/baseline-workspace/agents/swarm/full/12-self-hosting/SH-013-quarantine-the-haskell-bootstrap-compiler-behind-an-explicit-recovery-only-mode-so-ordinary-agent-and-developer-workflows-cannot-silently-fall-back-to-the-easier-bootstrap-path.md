# SH-013 Quarantine The Haskell Bootstrap Compiler Behind An Explicit Recovery-Only Mode So Ordinary Agent And Developer Workflows Cannot Silently Fall Back To The Easier Bootstrap Path

## Goal

Quarantine the Haskell bootstrap compiler behind an explicit recovery-only mode so ordinary agent and developer workflows cannot silently fall back to the easier bootstrap path

## Why

Clasp should eventually be able to carry its own compiler once the language and runtime are mature enough. This task belongs to the Self-Hosting track.

## Scope

- Implement `SH-013` as one narrow slice of work: Quarantine the Haskell bootstrap compiler behind an explicit recovery-only mode so ordinary agent and developer workflows cannot silently fall back to the easier bootstrap path
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

- `SH-012`

## Acceptance

- `SH-013` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
