# FB-003 Add A Browser/Client Runtime Helper For Generated Route Clients

## Goal

Add a browser/client runtime helper for generated route clients.

## Why

The first benchmark needs a real client-side consumer path, even if the UI remains host-rendered rather than fully Clasp-native.

## Scope

- Implement one narrow slice of work: add a small browser/client runtime helper layer that can execute generated route clients.
- Keep the helper focused on fetch-style calls, codec wiring, and error handling needed by the first benchmark slice.
- Add one example or regression path that exercises the helper against compiled route metadata.
- Avoid introducing a large frontend framework.

## Likely Files

- `runtime/`
- `src/Clasp/Emit/JavaScript.hs`
- `examples/`
- `benchmarks/`
- `test/Main.hs`

## Dependencies

- `FB-002`

## Acceptance

- Generated route clients can run through a small client runtime helper in a browser-like environment.
- Tests or regressions cover the happy path and one validation failure path.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
