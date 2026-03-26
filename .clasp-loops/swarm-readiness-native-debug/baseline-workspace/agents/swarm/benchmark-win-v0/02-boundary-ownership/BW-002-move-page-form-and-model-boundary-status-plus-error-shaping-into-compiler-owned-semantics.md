# BW-002 Move Page/Form And Model Boundary Status Plus Error Shaping Into Compiler-Owned Semantics

## Goal

Move page/form and model boundary status plus error shaping into compiler-owned semantics

## Why

The benchmark loss showed that `Clasp` agents still had to reason about host runtime wrappers to match request and model-boundary behavior. This task belongs to the benchmark-win remediation wave.

## Scope

- Implement `BW-002` as one narrow slice of work: make page/form request failures and model-boundary failures flow through compiler-owned semantics and generated runtime behavior
- Keep the solution focused on the current page/route/runtime surface rather than redesigning the whole error system
- Add or update regression coverage for request-boundary and model-boundary behavior in benchmark-shaped page flows
- Update docs/examples only where visible runtime behavior changes
- Avoid unrelated benchmark or auth work

## Likely Files

- `src/Clasp/Emit/JavaScript.hs`
- `runtime/bun/server.mjs`
- `examples/lead-app/`
- `test/Main.hs`
- `benchmarks/tasks/clasp-lead-segment/`
- `docs/clasp-spec-v0.md`

## Dependencies

- None within this focused wave.

## Acceptance

- `Clasp` page/form request failures and model-boundary failures in the benchmark app are shaped by compiler-owned/runtime-generated behavior
- A benchmark task like `lead-segment` no longer requires hand-normalizing generic runtime wrapper errors
- Regression coverage locks the behavior down
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
