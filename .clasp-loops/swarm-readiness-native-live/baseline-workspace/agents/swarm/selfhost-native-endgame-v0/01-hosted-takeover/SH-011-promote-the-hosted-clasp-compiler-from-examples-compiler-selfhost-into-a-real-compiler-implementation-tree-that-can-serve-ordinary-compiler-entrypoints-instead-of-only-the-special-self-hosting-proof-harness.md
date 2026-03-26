# SH-011 Promote The Hosted Clasp Compiler From Examples/Compiler-Selfhost Into A Real Compiler Implementation Tree That Can Serve Ordinary Compiler Entrypoints Instead Of Only The Special Self-Hosting Proof Harness

## Goal

Promote the hosted Clasp compiler from `examples/compiler-selfhost` into a real compiler implementation tree that can serve ordinary compiler entrypoints instead of only the special self-hosting proof harness

## Why

Clasp should eventually be able to carry its own compiler once the language and runtime are mature enough. This task belongs to the Self-Hosting track.

## Scope

- Implement `SH-011` as one narrow slice of work: Promote the hosted Clasp compiler from `examples/compiler-selfhost` into a real compiler implementation tree that can serve ordinary compiler entrypoints instead of only the special self-hosting proof harness
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

- `SH-010`

## Acceptance

- `SH-011` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
