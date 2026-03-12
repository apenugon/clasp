# AI-014 Add Secret-Aware Prompt And Tool-Input Surfaces That Consume Declared Secret Handles Instead Of Raw Ambient Strings

## Goal

Add secret-aware prompt and tool-input surfaces that consume declared secret handles instead of raw ambient strings

## Why

Typed model boundaries, tools, evals, and traces are central to the language thesis rather than an optional library layer. This task belongs to the AI-Native Platform track.

## Scope

- Implement `AI-014` as one narrow slice of work: Add secret-aware prompt and tool-input surfaces that consume declared secret handles instead of raw ambient strings
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

- `AI-013`

## Acceptance

- `AI-014` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
