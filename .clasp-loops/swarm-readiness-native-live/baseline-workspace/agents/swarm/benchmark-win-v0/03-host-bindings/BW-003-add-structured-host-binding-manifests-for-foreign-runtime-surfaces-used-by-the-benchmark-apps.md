# BW-003 Add Structured Host-Binding Manifests For Foreign Runtime Surfaces Used By The Benchmark Apps

## Goal

Add structured host-binding manifests for foreign runtime surfaces used by the benchmark apps

## Why

The current `Clasp` benchmark still leaves too much foreign-binding reasoning in free-form JavaScript. This task belongs to the benchmark-win remediation wave.

## Scope

- Implement `BW-003` as one narrow slice of work: define and emit a more structured host-binding contract for the benchmark app's foreign/runtime edges
- Focus on the benchmark app and its immediate reusable runtime surface rather than general host interop for every domain
- Add or update regression coverage showing that schema-shaped changes can be localized to structured binding data
- Update docs/examples only where the host-binding surface becomes more explicit
- Avoid unrelated native/backend/storage work

## Likely Files

- `src/Clasp/Emit/JavaScript.hs`
- `runtime/bun/`
- `examples/lead-app/`
- `benchmarks/tasks/clasp-lead-segment/`
- `test/Main.hs`
- `docs/clasp-spec-v0.md`

## Dependencies

- `BW-002`

## Acceptance

- The benchmark app's foreign/runtime surface is more structured and less ad hoc
- Ordinary field-propagation changes no longer require broad manual reasoning across free-form host bindings
- Regression coverage proves the generated/structured contract shape
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
