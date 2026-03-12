# SH-002 Add The Standard-Library Surface Needed By Compiler Code Written In Clasp

## Goal

Add the standard-library surface needed by compiler code written in Clasp

## Why

Clasp should eventually be able to carry its own compiler once the language and runtime are mature enough. This task belongs to the Self-Hosting track.

## Scope

- Implement `SH-002` as one narrow slice of work: Add the standard-library surface needed by compiler code written in Clasp
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

- `SH-001`

## Acceptance

- `SH-002` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
