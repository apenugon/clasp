# FB-002 Generate Typed JavaScript Route Clients From Route Declarations

## Goal

Generate typed JavaScript route clients from route declarations.

## Why

The first credible benchmark needs one shared app surface that reaches from server routes to a client-side consumer without hand-maintained glue.

## Scope

- Implement one narrow slice of work: derive a small typed JavaScript client surface from existing route metadata.
- Keep request and response validation at the boundary by reusing generated codecs.
- Add one demo or example path that shows a compiled module and generated client sharing the same route definition.
- Add or update regression coverage for the generated client surface.
- Avoid introducing a large framework.

## Likely Files

- `src/Clasp/Emit/JavaScript.hs`
- `runtime/`
- `examples/`
- `benchmarks/`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`

## Dependencies

- `FB-001`

## Acceptance

- Route declarations emit a small typed JavaScript client helper surface.
- Generated clients reuse the same generated request and response validation path as the server-side route metadata.
- Tests or regressions cover the generated client behavior.
- `bash scripts/verify-all.sh` passes.

## Verification

```sh
bash scripts/verify-all.sh
```
