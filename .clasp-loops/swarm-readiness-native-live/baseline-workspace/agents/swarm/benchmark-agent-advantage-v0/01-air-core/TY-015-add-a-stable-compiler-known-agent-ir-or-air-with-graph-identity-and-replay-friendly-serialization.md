# TY-015 Add A Stable Compiler-Known Agent IR Or AIR With Graph Identity And Replay-Friendly Serialization

## Goal

Add a stable compiler-known agent IR or AIR with graph identity and replay-friendly serialization

## Why

The benchmark loss analysis showed that agents still spend too much time reconstructing the semantic shape of the app from raw files. A compiler-known `AIR` is the narrowest foundation for better context graphs, UI graphs, and semantic edit operations on the benchmark path.

## Scope

- Implement `TY-015` as one focused slice of work on the current `main`
- Prefer the smallest `AIR` surface that can give stable graph identity to benchmark-relevant declarations and flows
- Add or update regression coverage for the new behavior
- Update docs only where the new visible machine interface changes benchmark-relevant behavior
- Avoid unrelated redesign outside the `AIR` foothold needed by later benchmark-helping tasks

## Likely Files

- `src/Clasp/Core.hs`
- `src/Clasp/Checker.hs`
- `src/Clasp/Lower.hs`
- `src/Clasp/Compiler.hs`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`

## Dependencies

- None within this focused wave.

## Acceptance

- `TY-015` is implemented in a way later benchmark-helping tasks can consume
- The compiler can emit or persist stable graph identity for benchmark-relevant declarations
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
