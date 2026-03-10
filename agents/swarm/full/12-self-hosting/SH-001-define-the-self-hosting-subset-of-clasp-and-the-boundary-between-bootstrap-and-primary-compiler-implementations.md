# SH-001 Define The Self-Hosting Subset Of Clasp And The Boundary Between Bootstrap And Primary Compiler Implementations

## Goal

Define the self-hosting subset of Clasp and the boundary between bootstrap and primary compiler implementations

## Why

Clasp should eventually be able to carry its own compiler once the language and runtime are mature enough. This task belongs to the Self-Hosting track.

## Scope

- Implement `SH-001` as one narrow slice of work: Define the self-hosting subset of Clasp and the boundary between bootstrap and primary compiler implementations
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

- `SA-010`

## Acceptance

- `SH-001` is implemented without breaking previously integrated tasks
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
