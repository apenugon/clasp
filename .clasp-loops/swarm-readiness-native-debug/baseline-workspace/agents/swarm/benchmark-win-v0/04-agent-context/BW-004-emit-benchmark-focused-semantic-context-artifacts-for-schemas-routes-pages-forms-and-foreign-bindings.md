# BW-004 Emit Benchmark-Focused Semantic Context Artifacts For Schemas, Routes, Pages, Forms, And Foreign Bindings

## Goal

Emit benchmark-focused semantic context artifacts for schemas, routes, pages, forms, and foreign bindings

## Why

If `Clasp` is going to beat `TypeScript`, agents need semantic context instead of falling back to grepping files or reading generated output. This task belongs to the benchmark-win remediation wave.

## Scope

- Implement `BW-004` as one narrow slice of work: emit machine-readable semantic context artifacts for the benchmark app surface
- Cover at least shared schema fields, page/render declarations, routes/forms, and foreign/runtime bindings
- Make the artifact easy to consume from benchmark workspaces
- Add or update regression coverage for artifact generation
- Update docs or benchmark guidance only where the artifact becomes part of the intended workflow
- Avoid broad daemon/protocol redesign

## Likely Files

- `src/Clasp/Core.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Compiler.hs`
- `examples/lead-app/`
- `benchmarks/`
- `test/Main.hs`

## Dependencies

- None within this focused wave.

## Acceptance

- Preparing the benchmark workspace can expose a machine-readable semantic context artifact for the `Clasp` app
- The artifact covers affected schemas, routes, forms, pages, and foreign bindings for tasks like `lead-segment`
- Regression coverage proves artifact generation remains stable
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
