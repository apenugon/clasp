# AI-016 Add First-Class Subagent Spawn, Join, Supervision, And Handoff Semantics With Delegated Capabilities And Scoped Context Packs

## Goal

Add first-class subagent spawn, join, supervision, and handoff semantics with delegated capabilities and scoped context packs

## Why

Typed model boundaries, tools, evals, and traces are central to the language thesis rather than an optional library layer. This task belongs to the AI-Native Platform track.

## Scope

- Implement `AI-016` as one narrow slice of work: Add first-class subagent spawn, join, supervision, and handoff semantics with delegated capabilities and scoped context packs
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/`
- `runtime/`
- `examples/`
- `benchmarks/`
- `test/Main.hs`
- `docs/`

## Dependencies

- `CP-019`
- `CP-022`
- `CP-028`
- `WF-010`

## Acceptance

- `AI-016` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
