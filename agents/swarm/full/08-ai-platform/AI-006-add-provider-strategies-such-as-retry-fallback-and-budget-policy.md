# AI-006 Add Provider Strategies Such As Retry, Fallback, And Budget Policy

## Goal

Add provider strategies such as retry, fallback, and budget policy

## Why

Typed model boundaries, tools, evals, and traces are central to the language thesis rather than an optional library layer. This task belongs to the AI-Native Platform track.

## Scope

- Implement `AI-006` as one narrow slice of work: Add provider strategies such as retry, fallback, and budget policy
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

- `AI-005`

## Acceptance

- `AI-006` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
