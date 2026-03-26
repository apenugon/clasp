# BW-001 Make The Mirrored Lead-Segment Benchmark Repos And Acceptance Surface Truly Isomorphic

## Goal

Make the mirrored `lead-segment` benchmark repos and acceptance surface truly isomorphic

## Why

The first `lead-segment` comparison is only useful if both language variants demand the same kind of product work. This task belongs to the benchmark-win remediation wave.

## Scope

- Implement `BW-001` as one narrow slice of work: make the mirrored `Clasp` and `TypeScript` `lead-segment` benchmark repos and acceptance surface truly isomorphic
- Ensure the intended change stays in app-level code and declared binding data rather than benchmark-only harness glue
- Add or update regression coverage for the benchmark prep/verification flow
- Update benchmark docs only where the benchmark contract becomes more precise
- Avoid unrelated language/runtime redesign

## Likely Files

- `benchmarks/tasks/clasp-lead-segment/`
- `benchmarks/tasks/ts-lead-segment/`
- `benchmarks/test-task-prep.sh`
- `benchmarks/README.md`
- `docs/clasp-benchmark-plan.md`
- `test/`

## Dependencies

- None within this focused wave.

## Acceptance

- The mirrored `lead-segment` task repos require comparable app-level changes on both sides
- The `Clasp` task no longer expects benchmark-only test/runtime edits for an ordinary product-field propagation change
- Regression coverage proves the intended starting state and acceptance surface are stable
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
