# SH-008 Build The Hosted Clasp Compiler In Clasp And Run It Through JS/Bun

## Goal

Build the hosted Clasp compiler in Clasp and run it through JS/Bun

## Why

Clasp should eventually be able to carry its own compiler once the language and runtime are mature enough. This task belongs to the Self-Hosting track.

## Scope

- Implement `SH-008` as one narrow slice of work: Build the hosted Clasp compiler in Clasp and run it through JS/Bun
- Add or update regression coverage for the new behavior
- Update docs or examples only where the new surface changes visible behavior
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `src/`
- `examples/`
- `docs/`
- `test/`
- `benchmarks/`

## Dependencies

- `SH-007`

## Acceptance

- `SH-008` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
