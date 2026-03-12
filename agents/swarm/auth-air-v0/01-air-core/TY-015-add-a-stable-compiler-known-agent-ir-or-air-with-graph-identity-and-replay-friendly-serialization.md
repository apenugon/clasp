# TY-015 Add A Stable Compiler-Known Agent IR Or AIR With Graph Identity And Replay-Friendly Serialization

## Goal

Add a stable compiler-known agent IR or AIR with graph identity and replay-friendly serialization

## Why

Clasp needs stronger typing and more useful diagnostics than mainstream baseline stacks if the language thesis is going to hold up. This task belongs to the Type System And Diagnostics track.

## Scope

- Implement `TY-015` as one narrow slice of work: Add a stable compiler-known agent IR or AIR with graph identity and replay-friendly serialization
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/Clasp/Core.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Diagnostic.hs`
- `src/Clasp/Lower.hs`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`

## Dependencies

- None within this focused wave.
- Assume the current `main` branch already provides the benchmark/runtime and tooling foundation this slice builds on.

## Acceptance

- `TY-015` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
