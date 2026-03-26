# Benchmark Win Wave v0

This wave is the shortest path to improving `Clasp` on the mirrored `lead-segment` benchmark.

It is intentionally narrower than the full language vision. The objective is:

- reduce the extra reasoning an agent currently has to do in `Clasp` compared with `TypeScript`
- make the mirrored benchmark pair more isomorphic and fair
- rerun the benchmark with enough instrumentation to tell whether the remediation work is helping

The first benchmark loss showed four concrete near-term problems:

- the `Clasp` task can spill into runtime or harness-adjacent glue instead of staying in the app surface
- request and model boundary behavior is not yet compiler-owned enough
- foreign/runtime bindings are still too free-form
- agents do not get semantic context artifacts for the benchmark app surface

This wave therefore focuses on:

- `01-benchmark-fairness`
- `02-boundary-ownership`
- `03-host-bindings`
- `04-agent-context`
- `05-reruns`

Success for this wave means:

- the mirrored `Clasp` and `TypeScript` task repos are more comparable
- the `Clasp` benchmark task no longer pushes agents into generated output or ad hoc runtime wrappers for ordinary schema-flow changes
- the repo can run repeated `lead-segment` series and summarize whether `Clasp` is closing the gap
