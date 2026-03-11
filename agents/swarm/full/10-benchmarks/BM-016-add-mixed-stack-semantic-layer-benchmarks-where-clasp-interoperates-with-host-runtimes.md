# BM-016 Add Mixed-Stack Semantic-Layer Benchmarks Where Clasp Interoperates With Host Runtimes

## Goal

Add mixed-stack semantic-layer benchmarks where `Clasp` interoperates with host runtimes.

## Why

The most credible early benchmark story is not an all-Clasp toy repo. It is whether `Clasp` can act as the primary semantic layer of a realistic system while interoperating with practical host runtimes. This task belongs to the Benchmark Program track.

## Scope

- Implement `BM-016` as one narrow slice of work: add mixed-stack semantic-layer benchmarks where `Clasp` interoperates with host runtimes.
- Focus on benchmark scenarios where shared contracts, trust boundaries, and app logic live in `Clasp` while one host-specific edge remains outside it.
- Include at least one benchmark that exercises a `JS` package boundary or provider SDK boundary without reducing the task to glue code.
- Add or update regression coverage for benchmark manifests, task descriptions, and result packaging.
- Update docs or examples only where the new surface changes visible behavior.
- Avoid unrelated refactors or broad rewrites

## Likely Files

- `benchmarks/`
- `examples/`
- `docs/clasp-benchmark-plan.md`
- `docs/clasp-project-plan.md`
- `scripts/`

## Dependencies

- `FS-011`
- `BM-012`

## Acceptance

- The benchmark suite includes at least one mixed-stack scenario where `Clasp` is the primary semantic layer and a host runtime remains behind a typed boundary.
- Benchmark packaging records the same task-level metrics used elsewhere in the suite.
- The new scenarios are reproducible and comparable against a practical baseline stack.
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
