# AI-011 Build One Real Clasp Agent App Using Typed Tools And Structured Outputs

## Goal

Build one real Clasp agent app using typed tools and structured outputs

## Why

Typed model boundaries, tools, evals, and traces are central to the language thesis rather than an optional library layer. This task belongs to the AI-Native Platform track.

## Scope

- Implement `AI-011` as one narrow slice of work: Build one real Clasp agent app using typed tools and structured outputs
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

- `AI-010`

## Acceptance

- `AI-011` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
