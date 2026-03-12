# BW-005 Add Repeated Lead-Segment Benchmark Series And Summary Reporting To Measure Remediation Progress

## Goal

Add repeated `lead-segment` benchmark series and summary reporting to measure remediation progress

## Why

One benchmark run is not enough to know whether `Clasp` is actually improving. This task belongs to the benchmark-win remediation wave.

## Scope

- Implement `BW-005` as one narrow slice of work: make repeated `lead-segment` runs and comparative summaries routine
- Focus on the existing benchmark harness rather than introducing a new benchmarking framework
- Add or update reporting and regression coverage where appropriate
- Update benchmark docs with the intended repeated-run workflow
- Avoid unrelated compiler or app changes

## Likely Files

- `benchmarks/run-benchmark.mjs`
- `benchmarks/run-codex-series.sh`
- `benchmarks/README.md`
- `benchmarks/results/`
- `scripts/verify-all.sh`
- `test/`

## Dependencies

- `BW-001`
- `BW-002`
- `BW-003`
- `BW-004`

## Acceptance

- The repo can run repeated mirrored `lead-segment` series for `Clasp` and `TypeScript`
- Summary output makes time-to-green, pass rate, and token deltas easy to compare over remediation runs
- Regression coverage or smoke coverage proves the workflow remains usable
- `bash scripts/verify-all.sh` passes

## Verification

```sh
bash scripts/verify-all.sh
```
