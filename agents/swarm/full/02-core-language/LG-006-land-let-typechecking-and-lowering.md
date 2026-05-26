# LG-006 Land Let Typechecking And Lowering

## Goal

Land `let` typechecking and lowering

## Why

The core language still needs enough control flow and ergonomics to support nontrivial application logic. This task belongs to the Core Language Surface track.

## Scope

- Implement `LG-006` as one narrow slice of work: Land `let` typechecking and lowering
- Add or update regression coverage for the new behavior
- If the task changes runtime behavior, trust boundaries, workflows, interop, or app/user-facing execution surfaces, add or update at least one scenario-level or end-to-end verification path
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Compiler/Ast.clasp`
- `runtime/claspc.rs`
- `src/Compiler/Checker.clasp`
- `src/Compiler/Lower.clasp`
- `src/Compiler/Emit/JavaScript.clasp`
- `scripts/`
- `test/`
- `docs/clasp-spec-v0.md`
- `examples/`

## Dependencies

- `LG-005`

## Acceptance

- `LG-006` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- Runtime, boundary, workflow, interop, or app-surface changes are backed by scenario-level or end-to-end verification, not only a local unit-style regression
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
