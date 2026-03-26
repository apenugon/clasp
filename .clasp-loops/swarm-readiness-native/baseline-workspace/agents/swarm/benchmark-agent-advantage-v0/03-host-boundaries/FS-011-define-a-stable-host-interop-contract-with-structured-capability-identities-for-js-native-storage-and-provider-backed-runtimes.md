# FS-011 Define A Stable Host-Interop Contract With Structured Capability Identities For JS, Native, Storage, And Provider-Backed Runtimes

## Goal

Define a stable host-interop contract with structured capability identities for `JS`, native, storage, and provider-backed runtimes

## Why

The benchmark still leaks too much runtime-glue reasoning into agent work. A stable host-interop contract is the narrowest way to make those foreign edges compiler-owned enough to stop dominating ordinary app changes.

## Scope

- Implement `FS-011` as one focused slice of work on stable structured host-boundary contracts
- Keep the first pass centered on the benchmark-relevant runtime surfaces
- Add or update regression coverage for the new behavior
- Update docs only where visible host-interop behavior changes
- Avoid unrelated FFI expansion

## Likely Files

- `src/Clasp/Checker.hs`
- `src/Clasp/Core.hs`
- `src/Clasp/Emit/JavaScript.hs`
- `runtime/bun/server.mjs`
- `test/Main.hs`

## Dependencies

- None within this focused wave.

## Acceptance

- `FS-011` is implemented without breaking the benchmark slice or previously integrated tasks
- Benchmark-relevant foreign/runtime surfaces are described by structured capability identities instead of free-form conventions alone
- Tests or regressions cover the new behavior
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
