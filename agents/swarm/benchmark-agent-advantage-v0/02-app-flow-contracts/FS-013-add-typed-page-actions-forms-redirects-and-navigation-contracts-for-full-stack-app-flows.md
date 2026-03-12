# FS-013 Add Typed Page Actions, Forms, Redirects, And Navigation Contracts For Full-Stack App Flows

## Goal

Add typed page actions, forms, redirects, and navigation contracts for full-stack app flows

## Why

The lead-inbox benchmark is exactly the kind of form and page-flow propagation task this feature should simplify. Tight compiler ownership over those contracts should reduce both discovery cost and repair loops.

## Scope

- Implement `FS-013` as one focused slice of work on the benchmark-relevant page/app surface
- Keep the work centered on page actions, forms, redirects, and navigation contracts rather than broad frontend redesign
- Add or update regression coverage for the new behavior
- Update docs only where visible full-stack behavior changes
- Avoid unrelated runtime or compiler rewrites

## Likely Files

- `src/Clasp/Checker.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `runtime/bun/server.mjs`
- `test/Main.hs`

## Dependencies

- None within this focused wave.

## Acceptance

- `FS-013` is implemented without breaking the benchmark slice or previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
