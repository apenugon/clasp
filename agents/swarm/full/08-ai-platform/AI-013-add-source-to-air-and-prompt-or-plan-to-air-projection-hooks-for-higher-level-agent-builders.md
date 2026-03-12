# AI-013 Add Source-To-AIR And Prompt-Or-Plan-To-AIR Projection Hooks For Higher-Level Agent Builders

## Goal

Add source-to-AIR and prompt-or-plan-to-AIR projection hooks for higher-level agent builders

## Why

Typed model boundaries, tools, evals, and traces are central to the language thesis rather than an optional library layer. This task belongs to the AI-Native Platform track.

## Scope

- Implement `AI-013` as one narrow slice of work: Add source-to-AIR and prompt-or-plan-to-AIR projection hooks for higher-level agent builders
- Add or update regression coverage for the new behavior
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

- `AI-012`

## Acceptance

- `AI-013` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
